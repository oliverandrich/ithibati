defmodule Ithibati.Identity.Passkeys do
  @moduledoc """
  The WebAuthn ceremony, both halves: enrolling a browser's credential as an account's passkey, and
  proving possession of one afterwards.

  Each half is a challenge, the options the browser reads, and a verification — which answers the
  credential to store on registration, and the account that holds it on authentication. Never a
  session: what is issued afterwards is a separate call to `Ithibati.Identity.Tokens`, and decision
  5 in `docs/design.md` explains why that separation is what makes a device token additive rather
  than a rewrite.

  Which of the choices here are this library's and which an application's: decision 7.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Identity.Secrets
  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User
  alias Ithibati.UserKey

  # WebAuthn Level 2, §5.1.3: a relying party must reject a credential id longer than 1023 bytes.
  # `Wax` does not — the length prefix is 16 bits, so an authenticator may claim up to 65535 — and
  # what arrives here is the browser's, which makes the size somebody else's choice.
  @credential_id_max 1023

  # Compared as strings by Wax, which is why an atom cannot be allowed through: `:required` renders
  # as `"required"` in the JSON the browser reads and matches nothing on the server, so the browser
  # enforces user verification and this library quietly does not.
  @user_verification ["required", "preferred", "discouraged"]

  # How long a challenge stays acceptable. Both ceremonies take it, and both tell the browser the
  # same number by reading it back off the challenge.
  @default_seconds 60

  @doc """
  Mints a registration challenge for this relying party.

  `verify_trust_root: false` and `attestation: "none"` go together: nothing here polices
  authenticator models, so nothing here asks for an attestation it would not check — and an
  authenticator that honoured the request would be refused for its trouble.

  Everything this library's behaviour depends on is passed rather than left out.
  `Wax.Challenge.new/1` fills any option it was *not* given from `Application.get_all_env(:wax_)`,
  so a consumer who configures `wax_` directly would otherwise decide the relying party, how long a
  ceremony may take, and which attestation types are trusted — the last of which refuses every
  registration if it does not list `:none`.

  `:user_verification` is the one choice here that is an application's rather than this library's:
  whether the authenticator must confirm who is holding it. It defaults to `"preferred"`, and
  `registration_options/3` reads it back off the challenge so the browser can never be asked for
  something the server will refuse. `:seconds` is how long the challenge stays acceptable.
  """
  def registration_challenge(rp_id, origin, opts \\ [])
      when is_binary(rp_id) and is_binary(origin) do
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

  Takes the account, or — before it exists — the identifier the invitation was addressed to. The
  only option is `:rp_name`, required, the name a passkey dialog shows.

  The credentials to exclude are read from this library's own table rather than passed in: their
  whole purpose is that one authenticator cannot enrol itself twice, and an argument that can be
  forgotten defeats it at exactly the call site that adds a second passkey.

  Three of the values are not negotiable and say why here rather than in the map. A **discoverable**
  credential is required — `required`, not `preferred`, because sign-in names no credential, so one
  the authenticator kept to itself would be invisible there, and a system with no passwords cannot
  leave the property it depends on to the authenticator's discretion. `requireResidentKey` is the
  same wish in the older spelling, which WebAuthn L2 asks for alongside it: a client implementing
  only L1 ignores `residentKey` and hands back a server-side credential that never appears at
  sign-in. And **`credProps`** is how the client answers a wish an authenticator may refuse;
  `verify_registration/2` is where that answer is acted on.

  The algorithms offered are ES256 and RS256, the two every authenticator in circulation supports.
  Ed25519 is deliberately absent rather than forgotten: nothing here has met an authenticator that
  offers it and not one of these two, and a list a consumer can extend is a published option this
  library has no caller for yet.
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
        # will refuse — the disagreement is silent and looks like a broken authenticator.
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

  Takes the `PublicKeyCredential` the browser produced, parsed — what `JSON.parse` gives for
  `credential.toJSON()`. Base64url decoding happens here rather than at the caller, for the same
  reason `registration_options/3` builds the browser's dictionary here: it is protocol detail, and
  decision 7 keeps protocol detail in the core.

  Whether the credential is discoverable comes from `clientExtensionResults.credProps.rk`, which is
  where the browser puts it. An explicit `false` refuses — a credential sign-in can never name is
  turned away now rather than at the person's next visit, where the platform says "no passkey
  available" and nothing explains it. Absent means the client does not implement the extension,
  which is silence rather than denial.
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

  # Matched rather than walked: `get_in/2` raises for a `"clientExtensionResults"` that is a string,
  # a number or a list, and those are bodies a client can post. Absent — or present in a shape this
  # library did not ask for — is a client that did not answer, which is silence rather than denial.
  defp discoverable(%{"clientExtensionResults" => %{"credProps" => %{"rk" => reported}}}),
    do: reported

  defp discoverable(_credential), do: nil

  @doc """
  The attributes of a credential to store, with whatever the browser called it.

  There is deliberately no third source for the name: naming the authenticator's make would mean
  mapping its AAGUID against a list nobody licenses. See decision 6.
  """
  def key_attrs(%{key_id: key_id, public_key: public_key}, label) do
    %{key_id: key_id, public_key: public_key, label: label}
  end

  @doc """
  Mints an authentication challenge, or `{:error, :no_credentials}` on an instance that has no
  passkey at all.

  Whether *any* credential exists is asked with `exists?` rather than by loading them, because
  loading them is the query this is here to prevent — and it is not a secret either way: a sign-in
  page on an instance with no account has nothing to offer.

  Read what that answer is, though: it is about the **deployment**, not about this relying party or
  this tenant. `ithibati_keys` carries no relying-party column, so an application serving several of
  them from one database gets an answer about all of them together.

  The options are `registration_challenge/3`'s, with one more pinned rather than offered:
  `silent_authentication_enabled` stays off. It is one of the values Wax fills from `config :wax_`
  when it is not passed, and it accepts an assertion made without the person being present.
  """
  def authentication_challenge(rp_id, origin, opts \\ [])
      when is_binary(rp_id) and is_binary(origin) do
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

  `allowCredentials` is empty, and sent so rather than omitted because the shape the browser reads
  should say what it means. See `authentication_challenge/3` for why it names nothing.
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

  Takes the `PublicKeyCredential` the browser produced, parsed, and decodes it here — see
  `verify_registration/2` for why that is this library's job rather than the caller's.

  The credential is looked up *before* `Wax.authenticate/6` and handed to it, which is the
  resident-key path: the challenge names no credential, so Wax takes the public key from that
  argument. The order is not a preference — asked afterwards, Wax refuses every sign-in with
  `:credential_id_mismatch`, having nothing on the challenge to match against.

  > #### The caller must delete the challenge after verifying, success or failure {: .warning}
  >
  > A challenge lives wherever the caller put it, and left in place the same assertion signs in
  > again for as long as it is young enough. Decision 7 in `docs/design.md` says why this library
  > cannot hold that property for you.

  The signature counter an authenticator reports is deliberately neither stored nor compared;
  decision 7 says why.
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
  # not that is the browser's input like any other, so it is refused rather than raised on.
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

  # Longer than any authenticator may issue, so it matches no row — answered here rather than by
  # asking, which keeps a body-sized parameter out of a bytea index lookup. `key_id` is `:binary`
  # and would accept it; the saving is the query, not a refusal Postgres would have made.
  defp fetch_key(_credential_id), do: {:error, :unknown_credential}

  # The write is the answer, and it brings the account back with it. Two properties in one statement:
  # a passkey revoked between the lookup above and this update would otherwise still sign in, and
  # Postgres reads the joined row in the same round trip, so a sign-in costs two rather than three —
  # on a database that is not on this host, a whole network round trip per sign-in.
  #
  # No test in this suite can reach that revocation window; it needs a second writer committing
  # inside this one's transaction. The correctness comes from the shape of the statement rather than
  # from a green run.
  defp touch(key) do
    query =
      from(k in UserKey,
        where: k.id == ^key.id,
        join: account in ^Config.user_schema(),
        on: account.id == k.user_id,
        select: account
      )

    case Config.repo().update_all(query, set: [last_used_at: DateTime.utc_now()]) do
      {1, [account]} -> {:ok, account}
      {0, _} -> {:error, :unknown_credential}
    end
  end

  @doc false
  # The one place a credential row is shaped. `Ithibati.Identity.Grant` writes the first passkey of
  # an invited account and would otherwise restate this field list, which is how the grant path ends
  # up storing something subtly different from the registration path.
  #
  # `key_attrs` is rebuilt rather than merged into: a caller whose map carries a string `"user_id"`
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
  # not refuse it — the registration simply carries no credential. Matched rather than assumed:
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
  # Only an explicit `false` refuses. `nil` is a client that does not implement `credProps` — that
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
  # rather than a fresh random one: an authenticator replaces a discoverable credential only when
  # the relying party and this handle both match, so a random one would leave a second passkey
  # behind every time somebody cancels an invitation and opens it again.
  #
  # It is deliberately *not* the identifier itself — WebAuthn says a user handle must not be
  # personally identifying — and it does not agree with the account id that the same person gets
  # afterwards. Nothing here resolves a credential by handle; sign-in goes by credential id.
  defp handle(%_{id: id}), do: to_string(id)
  defp handle(identifier) when is_binary(identifier), do: Secrets.digest(identifier)

  defp existing_credentials(%_{id: id}) do
    Config.repo().all(from k in UserKey, where: k.user_id == ^id, select: k.key_id)
  end

  defp existing_credentials(_identifier), do: []

  # Wax raises on some malformed input rather than answering; a caller gets the same error tuple
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
