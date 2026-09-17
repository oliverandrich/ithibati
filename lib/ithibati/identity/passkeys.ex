defmodule Ithibati.Identity.Passkeys do
  @moduledoc """
  Registers and verifies passkeys and manages an account's stored credentials.

  Registration uses `registration_challenge/3`, `registration_options/3` and
  `verify_registration/2`. Authentication uses `authentication_challenge/3`,
  `authentication_options/1` and `verify_authentication/2`.

  Registration verification returns attributes for a new credential; authentication verification
  returns the account that owns it. The caller decides what to store or issue afterwards.
  Neither verification function creates a session.

  Use `add_key/2`, `list_keys/1`, `rename_key/3` and `delete_key/3` for an existing account's
  passkeys. Create an account with its first passkey and recovery codes through
  `Ithibati.Identity.Grant.with_key_and_codes/3`.

  [Registering and signing in](ceremonies.md) shows both the Phoenix integration and direct calls.
  """

  import Ecto.Query

  alias Ithibati.Config
  alias Ithibati.Identity.Concurrency
  alias Ithibati.Identity.Mutations
  alias Ithibati.Identity.Secrets
  alias Ithibati.Schema.Identifier
  alias Ithibati.Schema.User
  alias Ithibati.UserKey

  # Share the storage limit with verification and lookup. A module attribute is needed because
  # guards cannot call `UserKey.credential_id_max/0`.
  @credential_id_max UserKey.credential_id_max()

  # Wax compares these values as strings. An atom can serialize correctly for the browser
  # yet fail to enable the corresponding server-side check.
  @user_verification ["required", "preferred", "discouraged"]

  @default_seconds 60

  @doc """
  Returns a `Wax.Challenge` for passkey registration.

  `rp_id` is the relying-party ID. `origin` is an expected origin or a non-empty list of accepted
  origins. Supply both explicitly from trusted application settings; do not reflect client input.

  ## Options

    * `:user_verification` — `"required"`, `"preferred"` (default) or `"discouraged"`.
      These values are strings, not atoms.
    * `:seconds` — challenge lifetime as a positive integer; defaults to `60`.

  Invalid option values raise `ArgumentError`. Registration does not require an existing account
  or credential, so this function returns the challenge directly rather than an `:ok` tuple.

  Ithibati requests no attestation and does not verify authenticator trust roots. It supplies the
  WebAuthn options it depends on explicitly so `wax_` application defaults do not alter them.

  Retain the challenge for `verify_registration/2`. The caller must enforce single use, including
  when verification fails.
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
  Returns `PublicKeyCredentialCreationOptions` with binary fields encoded as unpadded base64url.

  Pass the configured account struct when adding a passkey, or an approved identifier when
  creating an account. An account populates `excludeCredentials` from its stored passkeys;
  an identifier produces an empty exclusion list.

  The required `:rp_name` option supplies the display name of the relying party. User verification,
  attestation and timeout are taken from the challenge. The browser timeout is in milliseconds.

  Ithibati requires discoverable credentials because sign-in does not ask for an identifier.
  It sets both `residentKey` and `requireResidentKey` and requests the `credProps` extension.
  The offered algorithms are ES256 and RS256.
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
      # Sign-in discovers credentials without an identifier. Require resident credentials in both
      # current and legacy option forms so older clients receive the same requirement.
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        # Keep browser requirements aligned with server verification.
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
  Verifies a registration credential and returns attributes ready to store.

  `credential` is the decoded JSON object produced by the browser's `credential.toJSON()`;
  its keys are strings and its binary fields are base64url-encoded. Pass the retained
  registration challenge as the second argument.

  Returns `{:ok, %{key_id: binary, public_key: binary}}` or `{:error, reason}`. Pass successful
  attributes to `add_key/2` or `Ithibati.Identity.Grant.with_key_and_codes/3`; use `key_attrs/2`
  to add a label first. Verification does not write a credential.

  Library validation failures use atom reasons, including `:malformed_credential`,
  `:not_discoverable`, `:no_attested_credential` and `:credential_id_too_long`. Errors from
  `wax_` can be exception structs. Handle known atoms and provide a fallback for other reasons.

  An explicit `false` or `"false"` in `clientExtensionResults.credProps.rk` is rejected. An absent
  extension result is accepted for clients that do not report discoverability.

  The caller must consume the stored challenge on every verification attempt, successful or not.
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

  # Pattern matching tolerates malformed extension containers without raising before verification.
  defp discoverable(%{"clientExtensionResults" => %{"credProps" => %{"rk" => reported}}}),
    do: reported

  defp discoverable(_credential), do: nil

  @doc """
  Adds `label` to verified credential attributes.

  Accepts the map returned by `verify_registration/2` and returns a map containing `:key_id`,
  `:public_key` and `:label`. Label trimming, truncation and the `"Passkey"` fallback are applied
  when the credential is stored, not by this function.
  """
  def key_attrs(%{key_id: key_id, public_key: public_key}, label) do
    %{key_id: key_id, public_key: public_key, label: label}
  end

  @doc """
  Stores a verified passkey on an existing account.

  `account` must be a struct of the configured account schema. `key_attrs` must contain the
  verified `:key_id` and `:public_key`, with an optional `:label`. Use `verify_registration/2`
  and optionally `key_attrs/2` to obtain these attributes.

  Returns `{:ok, key}` or `{:error, :already_enrolled}` when the credential ID already exists,
  including on another account. Other invalid changesets raise `Ecto.InvalidChangesetError`,
  including a foreign-key failure if the account was deleted before the insert.

  Labels are truncated to `Ithibati.UserKey.label_max/0` graphemes and trimmed. A missing or blank
  label is stored as `"Passkey"`.

  For a new account, compose `Ithibati.Identity.Grant.with_key_and_codes/3` into its creation
  transaction instead.
  """
  def add_key(account, key_attrs) do
    key_attrs
    |> credential_changeset(account)
    |> Config.repo().insert(insert_mode())
    |> already_enrolled?()
  end

  # A uniqueness failure must not abort the caller's enclosing transaction. Use a savepoint
  # only when a transaction exists; standalone inserts cannot open one.
  # `Ithibati.Identity.PasskeysUnwrappedTest` covers the standalone path.
  defp insert_mode do
    if Config.repo().in_transaction?(), do: [mode: :savepoint], else: []
  end

  defp already_enrolled?({:ok, key}), do: {:ok, key}

  # Credential-ID collisions have a public error code. Other invalid writes raise, including
  # a deleted account: `Config.account!/1` validates the struct, not its continued existence.
  defp already_enrolled?({:error, changeset}) do
    if Concurrency.collided?(changeset, :key_id),
      do: {:error, :already_enrolled},
      else: raise(Ecto.InvalidChangesetError, action: :insert, changeset: changeset)
  end

  @doc """
  Returns the account's passkeys as a list of `Ithibati.UserKey` structs.

  Rows are ordered by `inserted_at`, then `id`, both ascending. The ID provides a stable order
  when timestamps are equal. Each row includes its label and `last_used_at` value.
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
  Renames a passkey belonging to the account and returns `{:ok, key}`.

  The label is truncated to `Ithibati.UserKey.label_max/0` graphemes, then trimmed. Blank and
  non-string values become `"Passkey"`. The update also changes `updated_at`.

  Returns `{:error, :not_found}` for a missing key, a key owned by another account or an invalid
  UUID. The update is scoped to the supplied account and cannot transfer ownership.
  """
  def rename_key(account, id, name) do
    account = Config.account!(account)

    with {:ok, id} <- key_id(id) do
      query = account |> own_key(id) |> select([key], key)

      Mutations.update_one(
        Config.repo(),
        query,
        [set: [label: UserKey.label(name), updated_at: DateTime.utc_now()]],
        :not_found
      )
    end
  end

  @doc """
  Deletes a passkey belonging to the account and returns `{:ok, key}`.

  Returns `{:error, :not_found}` for a missing key, a key owned by another account or an invalid
  UUID. By default, deleting the account's last passkey returns `{:error, :last_key}`. This
  protection also applies to concurrent deletions through this function.

  The `:last` option accepts `:refuse` (default) or `:allow`. Other values raise `ArgumentError`.
  With `last: :allow`, an account can be left without passkeys and must use recovery codes to
  sign in. If no credentials remain anywhere in the deployment, `authentication_challenge/3`
  returns `{:error, :no_credentials}`.
  """
  def delete_key(account, id, opts \\ []) do
    account = Config.account!(account)
    last = last!(opts)

    with {:ok, id} <- key_id(id) do
      repo = Config.repo()

      # Return a refusal as the transaction value: no write occurred, and rolling back would also
      # abort a caller's enclosing transaction.
      {:ok, outcome} = Concurrency.transaction(repo, fn -> revoke(repo, account, id, last) end)

      outcome
    end
  end

  defp last!(opts) do
    case Keyword.get(opts, :last, :refuse) do
      last when last in [:refuse, :allow] -> last
      other -> raise ArgumentError, "last: must be :refuse or :allow, got #{inspect(other)}"
    end
  end

  # Under READ COMMITTED, the delete needs a new statement snapshot after the account lock is
  # acquired. Combining the lock and sibling check in one statement would retain the pre-wait snapshot.
  defp revoke(repo, account, id, last) do
    # The account lock is needed only when protecting the final passkey.
    if last == :refuse, do: Concurrency.lock_account!(account.id)

    query =
      if repo.__adapter__() == Ecto.Adapters.MyXQL,
        do: mysql_deletable_key(repo, account, id, last),
        else: deletable_key(account, id, last)

    case Mutations.delete_one(repo, query) do
      {1, [key]} -> {:ok, key}
      {0, _none} -> refusal(repo, account, id, last)
    end
  end

  # MySQL cannot delete from a table also used in its subquery. The account lock
  # serializes removals, so check siblings in a separate READ COMMITTED statement.
  defp mysql_deletable_key(repo, account, id, last) do
    query = deletable_key(account, id, :allow)

    if last == :refuse and
         not repo.exists?(from(k in UserKey, where: k.user_id == ^account.id and k.id != ^id)),
       do: where(query, false),
       else: query
  end

  # All management queries must bind the key ID to its owner to prevent cross-account access.
  defp own_key(account, id) do
    from k in UserKey, as: :key, where: k.id == ^id and k.user_id == ^account.id
  end

  # Validate before querying so malformed route IDs return `:not_found` instead of an Ecto cast error.
  defp key_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # Check for a sibling in the delete predicate after taking the account lock. Bind the sibling
  # through `parent_as(:key)` so both parts of the query use the same owner.
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

  # This lookup classifies an unsuccessful delete; it does not authorize one. A key removed
  # between statements can correctly be reported as `:not_found`. With `:allow`, no lookup is needed.
  defp refusal(_repo, _account, _id, :allow), do: {:error, :not_found}

  defp refusal(repo, account, id, :refuse) do
    if repo.exists?(own_key(account, id)),
      do: {:error, :last_key},
      else: {:error, :not_found}
  end

  @doc """
  Returns `{:ok, challenge}` for authentication, or `{:error, :no_credentials}` if no passkey exists.

  The existence check covers the entire configured credential table. Credentials are not
  partitioned by relying-party ID or tenant in that table. This check is independent of
  `Ithibati.Identity.Instance.needs_setup?/0`, which reports the bootstrap claim state.

  `rp_id`, `origin` and the options have the same meanings as in `registration_challenge/3`.
  Ithibati explicitly disables silent authentication, so a `wax_` application setting cannot
  allow assertions without user presence.

  Retain the challenge for `verify_authentication/2` and enforce single use on every attempt.
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
  Returns `PublicKeyCredentialRequestOptions` with binary fields encoded as unpadded base64url.

  `allowCredentials` is empty so the browser can offer discoverable passkeys for the relying
  party. User verification and timeout come from the challenge; timeout is converted to
  milliseconds for the browser.
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
  Verifies an assertion and returns `{:ok, account}` or `{:error, reason}`.

  `credential` is the decoded JSON object produced by the browser's `credential.toJSON()`.
  Pass the retained authentication challenge as the second argument. The returned account is
  an instance of the configured account schema; no session or token is issued.

  On success, the credential's `last_used_at` is updated without changing `updated_at`.
  A credential removed before that update is reported as `:unknown_credential`.

  Library validation errors use atom reasons. `wax_` errors may be exception structs; see
  `verify_registration/2` for error handling. Ithibati does not store or compare authenticator
  signature counters.

  > #### Consume the challenge once {: .warning}
  >
  > The caller owns challenge storage and must prevent reuse, including concurrent attempts.
  > A failed verification must also consume the challenge. Leaving it available permits another
  > attempt with the same assertion while it remains valid.
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
         # Deserialize inside `safe_wax/1` so corrupt stored keys return verification errors.
         # The safe option restricts decoding of this library-owned serialized term.
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

  # Malformed client encoding should return an error tuple rather than raise.
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

  # Reject oversized IDs before querying to avoid unnecessary large bytea index lookups.
  defp fetch_key(_credential_id), do: {:error, :unknown_credential}

  # Authenticate only after updating a still-present credential. Deletion before the update
  # produces `:unknown_credential`, rather than authenticating from the earlier lookup.
  # Only `last_used_at` changes; `updated_at` continues to describe credential edits.
  defp touch(key) do
    repo = Config.repo()

    case repo.__adapter__() do
      adapter when adapter in [Ecto.Adapters.SQLite3, Ecto.Adapters.MyXQL] ->
        touch_transactional(repo, key)

      _adapter ->
        touch_joined(key)
    end
  end

  # These adapters cannot return a joined account. Keep the credential write and
  # account read in one transaction so deletion cannot pass between them.
  defp touch_transactional(repo, key) do
    {:ok, outcome} =
      Concurrency.transaction(repo, fn ->
        query = from k in UserKey, where: k.id == ^key.id, select: k

        with {:ok, touched} <-
               Mutations.update_one_in_transaction(
                 repo,
                 query,
                 [set: [last_used_at: DateTime.utc_now()]],
                 :unknown_credential
               ),
             account when not is_nil(account) <- repo.get(Config.user_schema(), touched.user_id) do
          {:ok, account}
        else
          _absent -> {:error, :unknown_credential}
        end
      end)

    outcome
  end

  defp touch_joined(key) do
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
  # The grant and standalone enrolment share this field mapping. Rebuild the map explicitly
  # so an untrusted `user_id` entry cannot override the account supplied by the caller.
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

  # Attested credential data may be absent. Match it before field access so malformed input
  # returns an error rather than raising outside `safe_wax/1`.
  defp attested_credential(%{
         attested_credential_data: %Wax.AttestedCredentialData{} = credential
       }) do
    if byte_size(credential.credential_id) <= @credential_id_max,
      do: {:ok, credential},
      else: {:error, :credential_id_too_long}
  end

  defp attested_credential(_auth_data), do: {:error, :no_attested_credential}

  # Reject explicit discoverability denials, including the string form. Missing extension
  # results remain compatible with clients that do not implement `credProps`.
  defp check_discoverable(reported) when reported in [false, "false"],
    do: {:error, :not_discoverable}

  defp check_discoverable(_reported), do: :ok

  # Reject structs from another schema before deriving a credential handle.
  defp subject(%_{} = account), do: Config.account!(account)

  # Use the same normalization as storage so repeated registration attempts derive the same handle.
  defp subject(identifier) when is_binary(identifier), do: Identifier.normalize(identifier)

  # Use a stable handle so retrying registration for one subject does not create a new handle
  # each time. Before account creation, hash the normalized identifier instead of sending it
  # as the handle. Existing accounts use their ID; authentication resolves by credential ID.
  defp handle(%_{id: id}), do: to_string(id)
  defp handle(identifier) when is_binary(identifier), do: Secrets.digest(identifier)

  defp existing_credentials(%_{id: id}) do
    Config.repo().all(from k in UserKey, where: k.user_id == ^id, select: k.key_id)
  end

  defp existing_credentials(_identifier), do: []

  # Normalize raised verification errors into the same tuple shape as returned failures.
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
