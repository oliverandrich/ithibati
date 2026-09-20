defmodule Ithibati.Identity.Instance do
  @moduledoc """
  Records the one-time claim of an instance by its first account.

  Use this for invitation-only registration, where the first account has nobody to invite it.
  The bootstrap row and its unique index enforce a single claim, including concurrent attempts.
  Open-registration applications need not use it. The default `initial_claim: :open` keeps existing
  integrations compatible. An application exposed before its first account exists should enable
  `initial_claim: :operator_code` and apply schema version 3; `claim/2` then requires a short-lived
  authorization from `authorize_code/1`. See [Invitations](invitations.md#protect-the-first-account-claim).

      alias Ecto.Multi
      alias MyApp.Accounts.User

      Multi.new()
      |> Multi.insert(:account, User.changeset(%User{}, attrs))
      |> Ithibati.Identity.Instance.claim()
      |> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
      |> MyApp.Repo.transaction()

  Place `claim/2` before the grant so a rejected claim does not generate recovery codes.
  The bootstrap record survives deletion of the account that claimed it.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Ithibati.Bootstrap
  alias Ithibati.Config
  alias Ithibati.Identity.Concurrency
  alias Ithibati.Identity.Secrets
  alias Ithibati.Identity.Steps
  alias Ithibati.SetupCode

  @doc """
  Returns `true` when the instance has no bootstrap claim, and `false` once it has been claimed.

  This checks `Ithibati.Bootstrap`, not the account or passkey tables. An application that never
  calls `claim/2` continues to need setup according to this function, regardless of account count.
  Deleting the account that made the claim does not reset it.

  Use this result to choose what a setup page displays. `claim/2` enforces the one-time claim
  inside the transaction; a prior `true` result does not reserve it.

  `Ithibati.Identity.Passkeys.authentication_challenge/3` separately checks for stored passkeys.
  A claimed instance can have no passkeys and still be accessible through recovery codes.
  """
  def needs_setup?, do: not Config.repo().exists?(Bootstrap)

  @authorization_seconds 600

  @doc """
  Issues or replaces the first-account operator code.

  Requires `initial_claim: :operator_code`. Returns `{:ok, code}` before the instance is claimed,
  or `{:error, :already_claimed}` afterwards. The code contains 32 random bytes encoded as
  Base64url. Only its SHA-256 digest is stored. Print the plaintext once from an explicit
  application-owned operator command; never include it in a web response or startup log.

  Rotation invalidates both the old code and session authorizations made from it. Issuance and
  claim synchronize through the code row. Errors from the repo propagate.
  """
  def issue_code do
    require_operator_code!()
    code = Secrets.token()
    digest = Secrets.digest(code)
    repo = Config.repo()

    Concurrency.transaction(repo, fn ->
      if not needs_setup?(), do: repo.rollback(:already_claimed)

      repo.insert!(%SetupCode{id: 1, digest: digest}, on_conflict: :nothing)

      repo.update_all(from(row in SetupCode, where: row.id == 1),
        set: [digest: digest, updated_at: DateTime.utc_now()]
      )

      if needs_setup?(), do: code, else: repo.rollback(:already_claimed)
    end)
  end

  @doc """
  Exchanges the current operator code for a ten-minute authorization.

  Returns `{:ok, proof}` or `{:error, :invalid_setup_code}`. Store the proof only in a protected,
  signed browser session. `authorized?/1` rechecks it before the passkey challenge; `claim/2`
  checks and consumes it again inside the registration transaction. The plaintext code is never
  placed in that session.
  """
  def authorize_code(code) when is_binary(code) do
    require_operator_code!()
    current = Config.repo().get(SetupCode, 1)
    candidate = Secrets.digest(String.trim(code))

    if current && byte_size(code) > 0 &&
         :crypto.hash_equals(candidate, current.digest) && needs_setup?() do
      {:ok,
       %{digest: current.digest, expires_at: System.system_time(:second) + @authorization_seconds}}
    else
      {:error, :invalid_setup_code}
    end
  end

  def authorize_code(_code) do
    require_operator_code!()
    {:error, :invalid_setup_code}
  end

  @doc "Returns whether a session authorization is unexpired and matches the current code."
  def authorized?(proof) do
    case {Config.initial_claim_mode(), proof} do
      {:operator_code, %{digest: digest, expires_at: expires_at}}
      when is_binary(digest) and byte_size(digest) == 32 and is_integer(expires_at) ->
        current = Config.repo().get(SetupCode, 1)

        expires_at > System.system_time(:second) && current != nil &&
          :crypto.hash_equals(digest, current.digest) && needs_setup?()

      _ ->
        false
    end
  end

  defp consume_authorization(repo, proof) do
    case Config.initial_claim_mode() do
      :open -> :ok
      :operator_code -> consume_code(repo, proof)
    end
  end

  defp consume_code(repo, proof) do
    if valid_proof?(proof),
      do: consume_current_code(repo, proof.digest),
      else: {:error, :setup_authorization_required}
  end

  defp consume_current_code(repo, digest) do
    {count, _} =
      repo.delete_all(
        from(row in SetupCode,
          where: row.id == 1 and row.digest == ^digest
        )
      )

    if count == 1, do: :ok, else: {:error, :setup_authorization_required}
  end

  defp valid_proof?(%{digest: digest, expires_at: expires_at})
       when is_binary(digest) and byte_size(digest) == 32 and is_integer(expires_at),
       do: expires_at > System.system_time(:second)

  defp valid_proof?(_proof), do: false

  defp require_operator_code! do
    Config.initial_claim_mode() == :operator_code ||
      raise ArgumentError,
            "operator codes require config :ithibati, initial_claim: :operator_code"
  end

  @doc """
  Appends a `:bootstrap` step to the multi and returns the multi.

  The `:account` option names an earlier step providing the account and defaults to `:account`.
  That step is required. In `initial_claim: :operator_code` mode, pass the proof from
  `authorize_code/1` as `authorization:`. Without a current, unexpired proof the `:bootstrap`
  step returns `:setup_authorization_required` and the account insert rolls back. In `:open`
  mode no proof is required. On success, `:bootstrap` contains the inserted
  `Ithibati.Bootstrap` row.

  An existing claim makes `Repo.transaction/1` return
  `{:error, :bootstrap, :already_claimed, changes_so_far}`. Other insert errors return a changeset
  as the reason under the same step name. The transaction rolls back on either failure.

  The unique index enforces this result even when callers attempt the first claim concurrently.
  """
  def claim(multi, opts \\ []) do
    # The unique index arbitrates concurrent claims. A preliminary existence check would not
    # reserve the claim and would add a query before the same insert.
    Multi.run(multi, :bootstrap, fn repo, changes ->
      with :ok <- consume_authorization(repo, opts[:authorization]) do
        account = Steps.account!(changes, opts)

        repo.insert(Bootstrap.changeset(%Bootstrap{}, %{user_id: account.id}))
        |> name_constraint()
      end
    end)
  end

  # Only a claim collision becomes `:already_claimed`; preserve other changeset failures.
  defp name_constraint({:ok, bootstrap}), do: {:ok, bootstrap}

  defp name_constraint({:error, changeset}) do
    if Keyword.has_key?(changeset.errors, :claimed),
      do: {:error, :already_claimed},
      else: {:error, changeset}
  end
end
