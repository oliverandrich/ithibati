defmodule Ithibati.Identity.Passkeys do
  @moduledoc """
  The WebAuthn ceremony, both halves: enrolling a browser's credential as an account's passkey, and
  proving possession of one afterwards. It also covers what an account can do with the credentials
  it holds: list them, rename one, revoke one.

  Each half is three calls: a challenge, the options the browser reads, and a verification.

      challenge = registration_challenge(rp_id, origin, opts)
      options = registration_options(challenge, identifier_or_account, rp_name: "MyApp")
      # hand `options` to the browser, keep `challenge` until its answer comes back
      {:ok, key_attrs} = verify_registration(credential, challenge)

  Signing in is `authentication_challenge/3`, `authentication_options/1` and
  `verify_authentication/2`. `Ithibati.Web.PasskeyController` is that sequence wired to routes, and
  `docs/ceremonies.md` shows it without Phoenix.

  A verification answers the credential to store on registration, and the account that holds it on
  authentication. It never answers a session. Whatever is issued afterwards is a separate call —
  `Ithibati.Identity.Sessions` for a browser, and whatever the application decided for anything
  else.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Identity.Concurrency
  alias Ithibati.Identity.Secrets
  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User
  alias Ithibati.UserKey

  # `Wax` does not refuse an over-long credential id, and what arrives here is the browser's,
  # which makes the size somebody else's choice. The length prefix is 16 bits, so an
  # authenticator may claim up to 65535. Read from the schema so that the refusal on the way in and the
  # one on the way out cannot come apart; a literal, because guards cannot call a function.
  @credential_id_max UserKey.credential_id_max()

  # Compared as strings by Wax, which is why an atom cannot be allowed through: `:required` renders
  # as `"required"` in the JSON the browser reads and matches nothing on the server, so the browser
  # enforces user verification and this library quietly does not.
  @user_verification ["required", "preferred", "discouraged"]

  # How long a challenge stays acceptable. Both ceremonies take it, and both tell the browser the
  # same number by reading it back off the challenge.
  @default_seconds 60

  @doc """
  Mints a registration challenge for this relying party, and answers it.

  It returns a `Wax.Challenge` on its own and not a tuple, because nothing here can refuse a
  registration and there is nothing to answer with. Keep the challenge until the browser replies,
  because `verify_registration/2` needs it, and spend it once, whether that reply verified or not.

  `verify_trust_root: false` and `attestation: "none"` go together. Ithibati does not police
  authenticator models, so it does not ask for an attestation it would not check. An authenticator
  that honoured the request would be refused for its trouble.

  Ithibati passes every option its behaviour depends on, never leaving one out.
  `Wax.Challenge.new` fills any option it was *not* given from `Application.get_all_env(:wax_)`, so
  an application that configures `wax_` directly would otherwise decide the relying party, how long
  a ceremony may take, and which attestation types are trusted. A trusted-types list that does not
  name `:none` refuses every registration.

  `origin` may be a list, and for a client that is not a browser page it usually is. An extension
  has a different stable origin in each browser, and an assertion carries whichever one it was made
  at. Every entry is accepted, and none of them is preferred.

  `:user_verification` is the one choice here that belongs to the application and not to
  Ithibati: whether the authenticator must confirm who is holding it. It defaults to `"preferred"`,
  and `registration_options/3` reads it back off the challenge, so the browser can never be asked
  for something the server will refuse. `:seconds` is how long the challenge stays acceptable.
  """
  def registration_challenge(rp_id, origin, opts \\ [])
      when is_binary(rp_id) and (is_binary(origin) or (is_list(origin) and origin != [])) do
    Wax.new_registration_challenge(
      rp_id: rp_id,
      origin: origin,
      verify_trust_root: false,
      attestation: "none",
      trusted_attestation_types: [:none],
      user_verification: user_verification!(opts),
      timeout: seconds!(opts)
    )
  end

  @doc """
  Builds the browser's `PublicKeyCredentialCreationOptions`, binary fields base64url-encoded.

  It takes the account, or the identifier the invitation was addressed to when the account does not
  exist yet. The only option is `:rp_name`, which is required and is the name a passkey dialog
  shows.

  The credentials to exclude come from Ithibati's own table, not from an argument. Their
  purpose is that one authenticator cannot enrol itself twice, and an argument that can be forgotten
  defeats that at the call site which adds a second passkey.

  Three of the values are not negotiable, and the reasons are here, not in the map. A
  **discoverable** credential is required, and `required`, not `preferred`: sign-in names no
  credential, so one the authenticator kept to itself would be invisible there, and a system with no
  passwords cannot leave the property it depends on to the authenticator's discretion.
  `requireResidentKey` is the same wish in the older spelling, and WebAuthn L2 asks for it alongside
  `residentKey`. A client implementing only L1 ignores `residentKey` and hands back a server-side
  credential that never appears at sign-in. **`credProps`** is how the client answers a wish an
  authenticator may refuse, and `verify_registration/2` acts on that answer.

  The algorithms offered are ES256 and RS256, the two every authenticator in circulation supports.
  Ed25519 is deliberately absent, not forgotten. Nothing here has met an authenticator that
  offers it and not one of these two, and a list an application can extend is a published option
  Ithibati has no caller for yet.
  """
  def registration_options(challenge, account_or_identifier, opts) do
    subject = subject(account_or_identifier)
    rp_name = Keyword.fetch!(opts, :rp_name)
    %{name: name, display_name: display_name} = User.credential_user(subject)

    %{
      challenge: Secrets.url64(challenge.bytes),
      rp: %{id: challenge.rp_id, name: rp_name},
      user: %{id: Secrets.url64(handle(subject)), name: name, displayName: display_name},
      pubKeyCredParams: [
        %{type: "public-key", alg: -7},
        %{type: "public-key", alg: -257}
      ],
      # `required`, not `preferred`: sign-in names no credential, so one the authenticator kept to
      # itself would be invisible there. A system with no passwords cannot leave the property it
      # depends on to the authenticator's discretion.
      #
      # `requireResidentKey` is the same wish in the older spelling, and WebAuthn L2 asks for both:
      # a client implementing only L1 ignores `residentKey` and hands back a server-side credential
      # that then never appears at sign-in.
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        # Read off the challenge, all three, so the browser cannot be asked for something the server
        # will refuse. That disagreement is silent and looks like a broken authenticator.
        userVerification: challenge.user_verification
      },
      extensions: %{credProps: true},
      excludeCredentials:
        Enum.map(existing_credentials(subject), &%{type: "public-key", id: Secrets.url64(&1)}),
      attestation: challenge.attestation,
      timeout: challenge.timeout * 1000
    }
  end

  @doc """
  Verifies a registration and answers the credential to store.

  It answers `{:ok, %{key_id: binary, public_key: binary}}`, which `add_key/2` takes as it is and
  `key_attrs/2` takes to put a label on.

  A refusal is `{:error, reason}`, and `reason` is not always an atom: Ithibati's own refusals
  are atoms, and `wax_` answers with an exception struct, which passes through unchanged. Match
  on the atoms you handle and treat the rest as a failed verification, which is what
  `Ithibati.Web.PasskeyController` does.

  It takes the `PublicKeyCredential` the browser produced, parsed: what `JSON.parse` gives for
  `credential.toJSON()`. Base64url decoding happens here, not at the caller, for the same
  reason `registration_options/3` builds the browser's dictionary here. It is protocol detail,
  and protocol detail belongs in one place, not in every caller.

  Whether the credential is discoverable comes from `clientExtensionResults.credProps.rk`, which is
  where the browser puts it. An explicit `false` refuses. A credential that sign-in can never
  name is turned away now, not at the person's next visit, where the platform says "no passkey
  available" and nothing explains it. An absent value means the client does not implement the
  extension, which is silence and not denial.
  """
  def verify_registration(credential, challenge)

  def verify_registration(
        %{"response" => %{"attestationObject" => object, "clientDataJSON" => client_data}} =
          credential,
        challenge
      ) do
    with :ok <- check_discoverable(discoverable(credential)),
         {:ok, object} <- decode(object),
         {:ok, client_data} <- decode(client_data),
         {:ok, {auth_data, _attestation}} <-
           safe_wax(fn -> Wax.register(object, client_data, challenge) end),
         {:ok, attested} <- attested_credential(auth_data) do
      {:ok,
       %{
         key_id: attested.credential_id,
         public_key: :erlang.term_to_binary(attested.credential_public_key)
       }}
    end
  end

  def verify_registration(_credential, _challenge), do: {:error, :malformed_credential}

  # Matched, not walked. `get_in/2` raises for a `"clientExtensionResults"` that is a string,
  # a number or a list, and those are bodies a client can post. Absent, or present in a shape this
  # library did not ask for, is a client that did not answer. That is silence, not denial.
  defp discoverable(%{"clientExtensionResults" => %{"credProps" => %{"rk" => reported}}}),
    do: reported

  defp discoverable(_credential), do: nil

  @doc """
  The attributes of a credential to store, with whatever the browser called it.

  There is deliberately no third source for the name. Naming the authenticator's make would mean
  mapping its AAGUID against a list nobody licenses.
  """
  def key_attrs(%{key_id: key_id, public_key: public_key}, label) do
    %{key_id: key_id, public_key: public_key, label: label}
  end

  @doc """
  Enrols a credential on an account that already exists: a second device, or a replacement.

  It does for an existing account what `Ithibati.Identity.Grant.with_key_and_codes/3` does for one
  being created. It takes what `key_attrs/2` returned and answers `{:ok, key}`.

  `{:error, :already_enrolled}` is the one refusal, and it should be rare.
  `registration_options/3` puts this account's credentials in `excludeCredentials`, so a browser
  that honours it never offers an authenticator it has already enrolled here. The unique index
  answers for a browser that does not, and for the same authenticator arriving on a *different*
  account. That is the same collision, because a credential identifies a device, not a
  person.
  """
  def add_key(account, key_attrs) do
    key_attrs
    |> credential_changeset(account)
    |> Config.repo().insert(insert_mode())
    |> already_enrolled?()
  end

  # `mode: :savepoint` inside somebody's transaction, because the refusal below is a constraint
  # violation and Postgres aborts the surrounding transaction on one: without it a caller who
  # composed this into a transaction of their own would get `{:error, :already_enrolled}` and
  # then `25P02` on their next statement.
  #
  # And *only* inside one, because Ecto raises `transaction is not started` for a savepoint with
  # nothing to hang it on. That is every standalone call, the one the documentation shows. The
  # suite could not see that: the sandbox wraps each test in a transaction, so the savepoint
  # always had one. `Ithibati.Identity.PasskeysUnwrappedTest` runs without it.
  defp insert_mode do
    if Config.repo().in_transaction?(), do: [mode: :savepoint], else: []
  end

  defp already_enrolled?({:ok, key}), do: {:ok, key}

  # The unique index is the only failure a caller can act on. A foreign key that no longer points
  # anywhere, say an account deleted between the read and this write, raises instead.
  # `generate_session_token/1` does the same; `Ithibati.Config.account!/1` checks the struct's
  # module, not that its row still exists.
  defp already_enrolled?({:error, changeset}) do
    if Concurrency.collided?(changeset, :key_id),
      do: {:error, :already_enrolled},
      else: raise(Ecto.InvalidChangesetError, action: :insert, changeset: changeset)
  end

  @doc """
  The credentials this account has, oldest first.

  It answers full rows, because a person is shown the label and when the credential was last used.
  The ordering carries a tiebreaker on purpose: Postgres gives equal sort keys no defined order, so
  two rows that do share an `inserted_at` could come back either way round, and a list whose order
  moves between renders is one nobody can click in.
  """
  def list_keys(account) do
    account = Config.account!(account)

    Config.repo().all(
      from k in UserKey,
        where: k.user_id == ^account.id,
        order_by: [asc: k.inserted_at, asc: k.id]
    )
  end

  @doc """
  Gives one of this account's passkeys the name a person chose, and answers `{:ok, key}`.

  The name goes through the same cut and the same fallback as an enrolment's, so a list cannot end
  up showing two kinds of row. `{:error, :not_found}` covers a credential that does not exist and
  one that belongs to somebody else, which are the same answer to the person asking. It also covers
  an id that is not an id at all, because an id arrives from a route a person can type into.

  The account rides the `WHERE` of the update, and `user_id` is not among the columns written, so a
  rename cannot move a credential to another account. That is a property of the statement rather
  than of a validation a later edit could drop.
  """
  def rename_key(account, id, name) do
    account = Config.account!(account)

    with {:ok, id} <- key_id(id) do
      account
      |> own_key(id)
      |> select([key], key)
      |> Config.repo().update_all(
        set: [label: UserKey.label(name), updated_at: DateTime.utc_now()]
      )
      |> Concurrency.one_affected(:not_found)
    end
  end

  @doc """
  Revokes one of this account's passkeys, and answers `{:ok, key}`.

  It refuses the last one with `{:error, :last_key}`. Pass `last: :allow` to delete it anyway.

  That refusal is a default, not an invariant, and the difference is the one that
  matters: recovery codes still reach the account, so an application that overrides it breaks
  nothing
  Ithibati guarantees. The default is set this way because of what follows the deletion. A single
  sheet of one-time codes becomes the whole way in, and the person revoking a passkey is rarely
  the person who will go looking for that sheet. On a single-account instance the sign-in page
  empties too: `authentication_challenge/3` answers `{:error, :no_credentials}` once no passkey
  is left.

  `{:error, :not_found}` covers a credential that does not exist, one that belongs to somebody
  else, and an id that is not an id. Ithibati keeps it apart from `:last_key` deliberately. Hearing
  "that is your last one" about a credential that was never theirs sends somebody hunting for a
  device they do not have.
  """
  def delete_key(account, id, opts \\ []) do
    account = Config.account!(account)
    last = last!(opts)

    with {:ok, id} <- key_id(id) do
      repo = Config.repo()

      # The refusal is the transaction's *value*, not a `rollback/1`. Unlike `RecoveryCodes.redeem/2`,
      # this path has written nothing when it refuses, so aborting a caller's enclosing transaction
      # would be a side effect of saying no.
      {:ok, outcome} = repo.transaction(fn -> revoke(repo, account, id, last) end)

      outcome
    end
  end

  defp last!(opts) do
    case Keyword.get(opts, :last, :refuse) do
      last when last in [:refuse, :allow] -> last
      other -> raise ArgumentError, "last: must be :refuse or :allow, got #{inspect(other)}"
    end
  end

  # Two statements, and that is the mechanism, not a tidiness: one statement evaluates against
  # one snapshot, so an `EXISTS` sitting beside the `FOR NO KEY UPDATE` would be computed from the
  # stand before the wait and the lock would buy nothing. The delete has to be the second statement,
  # taking a fresh snapshot after it.
  defp revoke(repo, account, id, last) do
    # The lock exists for the invariant, so it is taken only where there is one: with `last: :allow`
    # there is no set a second deleter could empty, and nothing to queue on.
    if last == :refuse, do: Concurrency.lock_account!(account.id)

    case repo.delete_all(deletable_key(account, id, last)) do
      {1, [key]} -> {:ok, key}
      {0, _none} -> refusal(repo, account, id, last)
    end
  end

  # The one place a key is named together with the account allowed to touch it. Written once because
  # it is the authorization boundary of all three functions below, and a fourth reader that forgets
  # a term would not crash. It would answer about somebody else's row.
  defp own_key(account, id) do
    from k in UserKey, as: :key, where: k.id == ^id and k.user_id == ^account.id
  end

  # `id` is a `binary_id`, and Ecto raises instead of matching nothing when what it is handed is not
  # a UUID, so a hand-edited address would be a 500 where the documented answer is a refusal. Asked
  # before the transaction opens, so nothing is locked on the way to saying no.
  defp key_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # "The owner has another one" rides the `WHERE` of the delete, so no count is read and then acted
  # on. Why it needs the lock above as well is `Ithibati.Identity.Concurrency.lock_rows/1`'s to
  # explain: the two deletes aim at different rows and so wait on nothing.
  #
  # `parent_as(:key)`, not the account's id again. The outer `WHERE` has pinned the owner
  # already, and reading it off that row keeps the two halves from disagreeing.
  defp deletable_key(account, id, :allow), do: account |> own_key(id) |> select([key], key)

  defp deletable_key(account, id, :refuse) do
    account
    |> own_key(id)
    |> where(
      [key],
      exists(
        from(other in UserKey,
          where: other.user_id == parent_as(:key).user_id and other.id != parent_as(:key).id,
          select: 1
        )
      )
    )
    |> select([key], key)
  end

  # A second statement, and on READ COMMITTED a second snapshot. Sharing the transaction with the
  # delete buys no agreement between the two. That is acceptable because of what is being decided:
  # not whether to delete, which already happened, but which of two refusals to name. A key removed
  # by some other route in between is reported as `:not_found`, which by then is the true answer.
  # Nothing deleted has only one cause once the last one may go, so there is nothing to ask.
  defp refusal(_repo, _account, _id, :allow), do: {:error, :not_found}

  defp refusal(repo, account, id, :refuse) do
    if repo.exists?(own_key(account, id)),
      do: {:error, :last_key},
      else: {:error, :not_found}
  end

  @doc """
  Mints an authentication challenge: `{:ok, %Wax.Challenge{}}`, or `{:error, :no_credentials}` on
  an instance that has no passkey at all.

  Ithibati asks whether *any* credential exists with `exists?` instead of loading them, because
  loading them is the query this call is here to prevent. The answer is not a secret either way: a
  sign-in page on an instance with no account has nothing to offer.

  It is also not the question `Ithibati.Identity.Instance.needs_setup?/0` answers, which says how
  the two differ and when they disagree.

  Read the answer carefully, though: it is about the **deployment**, not about this relying party or
  this tenant. `ithibati_keys` carries no relying-party column, so an application serving several of
  them from one database gets an answer about all of them together.

  The options are `registration_challenge/3`'s, with one more pinned instead of offered.
  `silent_authentication_enabled` stays off. Wax fills it from `config :wax_` when it is not passed,
  and it accepts an assertion made without the person being present.
  """
  def authentication_challenge(rp_id, origin, opts \\ [])
      when is_binary(rp_id) and (is_binary(origin) or (is_list(origin) and origin != [])) do
    if Config.repo().exists?(UserKey) do
      {:ok,
       Wax.new_authentication_challenge(
         rp_id: rp_id,
         origin: origin,
         user_verification: user_verification!(opts),
         timeout: seconds!(opts),
         silent_authentication_enabled: false
       )}
    else
      {:error, :no_credentials}
    end
  end

  @doc """
  Builds the browser's `PublicKeyCredentialRequestOptions`, binary fields base64url-encoded.

  `allowCredentials` is empty, and it is sent that way and not omitted, because the shape the
  browser reads should say what it means. See `authentication_challenge/3` for why it names nothing.
  """
  def authentication_options(challenge) do
    %{
      challenge: Secrets.url64(challenge.bytes),
      rpId: challenge.rp_id,
      allowCredentials: [],
      userVerification: challenge.user_verification,
      timeout: challenge.timeout * 1000
    }
  end

  @doc """
  Verifies an assertion and answers the account that owns the credential.

  It answers `{:ok, account}`, the account struct the application configured. Nothing has been
  issued to that account yet; that is `c:Ithibati.Web.Handler.authenticate/2`'s decision.

  A refusal is `{:error, reason}`, and `reason` is not always an atom. See
  `verify_registration/2`, which says what to do about it.

  It takes the `PublicKeyCredential` the browser produced, parsed, and decodes it here. See
  `verify_registration/2` for why that is Ithibati's job and not the caller's.

  Ithibati looks the credential up *before* `Wax.authenticate/6` and hands it over, which is the
  resident-key path: the challenge names no credential, so Wax takes the public key from that
  argument. The order is not a preference. Asked afterwards, Wax refuses every sign-in with
  `:credential_id_mismatch`, having nothing on the challenge to match against.

  > #### The caller must delete the challenge after verifying, success or failure {: .warning}
  >
  > A challenge lives wherever the caller put it, and left in place the same assertion signs in
  > again for as long as it is young enough. Ithibati cannot hold that property for you: it
  > never sees where the challenge was put.

  Ithibati deliberately neither stores nor compares the signature counter an authenticator
  reports. It exists to detect a cloned authenticator, and a synced passkey reports zero forever,
  so a comparison either says nothing or locks out the person whose credential moved between
  devices.
  """
  def verify_authentication(credential, challenge)

  def verify_authentication(
        %{
          "id" => id,
          "response" => %{
            "authenticatorData" => auth_data,
            "clientDataJSON" => client_data,
            "signature" => signature
          }
        },
        challenge
      ) do
    with {:ok, credential_id} <- decode(id),
         {:ok, auth_data} <- decode(auth_data),
         {:ok, client_data} <- decode(client_data),
         {:ok, signature} <- decode(signature),
         {:ok, key} <- fetch_key(credential_id),
         # Decoded *inside* the rescue, not beside it: a truncated or unreadable stored key raises,
         # and out here that is a crash with a stale challenge instead of the refusal every other bad
         # assertion gets. `:safe` blocks atom and function creation; the binary is one this library
         # wrote itself.
         {:ok, _auth_data} <-
           safe_wax(fn ->
             cose_key = :erlang.binary_to_term(key.public_key, [:safe])

             Wax.authenticate(credential_id, auth_data, signature, client_data, challenge, [
               {credential_id, cose_key}
             ])
           end) do
      touch(key)
    end
  end

  def verify_authentication(_credential, _challenge), do: {:error, :malformed_credential}

  # Unpadded, which is the alphabet the browser writes and `*_options/1` reads back. A field that is
  # not that is the browser's input like any other. It is refused, never raised on.
  defp decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :malformed_credential}
    end
  end

  defp decode(_value), do: {:error, :malformed_credential}

  defp fetch_key(credential_id)
       when is_binary(credential_id) and byte_size(credential_id) <= @credential_id_max do
    case Config.repo().get_by(UserKey, key_id: credential_id) do
      %UserKey{} = key -> {:ok, key}
      nil -> {:error, :unknown_credential}
    end
  end

  # Longer than any authenticator may issue, so it matches no row. Answered here and not by
  # asking, which keeps a body-sized parameter out of a bytea index lookup. `key_id` is `:binary`
  # and would accept it; the saving is the query, not a refusal Postgres would have made.
  defp fetch_key(_credential_id), do: {:error, :unknown_credential}

  # The write is the answer, and it brings the account back with it. Two properties in one statement:
  # a passkey revoked between the lookup above and this update would otherwise still sign in, and
  # Postgres reads the joined row in the same round trip, so a sign-in costs two round trips, not three.
  # On a database that is not on this host, that saves a whole network round trip per sign-in.
  #
  # `updated_at` is deliberately left where it is, unlike a rename's: signing in is not a change to
  # the credential, and moving it would make "when was this row last edited" mean two things.
  #
  # No test in this suite can reach that revocation window; it needs a second writer committing
  # inside this one's transaction. The correctness comes from the shape of the statement, not
  # from a green run.
  defp touch(key) do
    query =
      from(k in UserKey,
        where: k.id == ^key.id,
        join: account in ^Config.user_schema(),
        on: account.id == k.user_id,
        select: account
      )

    Config.repo().update_all(query, set: [last_used_at: DateTime.utc_now()])
    |> Concurrency.one_affected(:unknown_credential)
  end

  @doc false
  # The one place a credential row is shaped. `Ithibati.Identity.Grant` writes the first passkey of
  # an invited account and would otherwise restate this field list, which is how the grant path ends
  # up storing something subtly different from the registration path.
  #
  # `key_attrs` is rebuilt, never merged into. A caller whose map carries a string `"user_id"`
  # would otherwise get an atom one beside it, and which of the two Ecto reads is a detail of
  # `Ecto.Changeset`'s parameter handling. The account is the caller's to name, not the map's.
  def credential_changeset(key_attrs, account) do
    %{key_id: key_id, public_key: public_key} = attrs = normalise(key_attrs)

    UserKey.changeset(%UserKey{}, %{
      key_id: key_id,
      public_key: public_key,
      label: attrs[:label],
      user_id: Config.account!(account).id
    })
  end

  defp normalise(%{key_id: _key_id, public_key: _public_key} = key_attrs), do: key_attrs

  defp normalise(other) do
    raise ArgumentError,
          "key_attrs: expected what `key_attrs/2` returns — a map with :key_id and :public_key — " <>
            "got #{inspect(other)}"
  end

  # An authenticator that sets no attested-credential-data flag leaves this `nil`, and `Wax` does
  # not refuse it. The registration simply carries no credential. Matched, never assumed:
  # the input is the browser's, and reading a field off `nil` would raise outside the rescue above,
  # which is the crash-with-a-stale-challenge this whole path exists to avoid.
  defp attested_credential(%{
         attested_credential_data: %Wax.AttestedCredentialData{} = credential
       }) do
    if byte_size(credential.credential_id) <= @credential_id_max,
      do: {:ok, credential},
      else: {:error, :credential_id_too_long}
  end

  defp attested_credential(_auth_data), do: {:error, :no_attested_credential}

  # An authenticator that says it did *not* store a discoverable credential is turned away here,
  # ahead of Wax: nothing about the attestation matters once the credential is one that sign-in can
  # never name, and the person is better told now than at their next visit, where the platform says
  # "no passkey available" and nothing explains it.
  #
  # Only an explicit `false` refuses. `nil` is a client that does not implement `credProps`. That
  # is silence, not a denial, and turning it away would lock out every browser that has not caught
  # up. `"false"` counts as the same denial: a form-encoded body, or anything routed through a DOM
  # attribute, hands over a string, and a guard matching the atom alone would wave it through with
  # the whole suite green.
  defp check_discoverable(reported) when reported in [false, "false"],
    do: {:error, :not_discoverable}

  defp check_discoverable(_reported), do: :ok

  # Checked the way every other entry point that takes an account checks it: an application with two
  # schemas using this library would otherwise build a ceremony against the wrong one's handle.
  defp subject(%_{} = account), do: Config.account!(account)

  # Through the same normalisation the identifier will go through when the account row is written,
  # so the derived handle is the same on a second attempt whatever case the invitation link carried.
  defp subject(identifier) when is_binary(identifier), do: Identifier.normalize(identifier)

  # The account's own key once there is a row, and before that a value derived from the identifier
  # and not a fresh random one: an authenticator replaces a discoverable credential only when
  # the relying party and this handle both match, so a random one would leave a second passkey
  # behind every time somebody cancels an invitation and opens it again.
  #
  # It is deliberately *not* the identifier itself, because WebAuthn says a user handle must not be
  # personally identifying. It does not agree with the account id that the same person gets
  # afterwards either. Nothing here resolves a credential by handle; sign-in goes by credential id.
  defp handle(%_{id: id}), do: to_string(id)
  defp handle(identifier) when is_binary(identifier), do: Secrets.digest(identifier)

  defp existing_credentials(%_{id: id}) do
    Config.repo().all(from k in UserKey, where: k.user_id == ^id, select: k.key_id)
  end

  defp existing_credentials(_identifier), do: []

  # Wax raises on some malformed input instead of answering. A caller gets the same error tuple
  # either way, because the alternative is a crash with a stale challenge left behind it.
  defp safe_wax(fun) do
    fun.()
  rescue
    error -> {:error, error}
  end

  defp user_verification!(opts) do
    case Keyword.get(opts, :user_verification, "preferred") do
      value when value in @user_verification ->
        value

      other ->
        raise ArgumentError,
              "user_verification: must be one of #{inspect(@user_verification)}, got #{inspect(other)}"
    end
  end

  defp seconds!(opts) do
    case Keyword.get(opts, :seconds, @default_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      other -> raise ArgumentError, "seconds: must be a positive integer, got #{inspect(other)}"
    end
  end
end
