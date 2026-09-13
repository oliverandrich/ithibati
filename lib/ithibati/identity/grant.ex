defmodule Ithibati.Identity.Grant do
  @moduledoc """
  The credential half of creating an account, as a fragment an application composes into its own
  transaction.

  The passkey and the recovery codes belong in the same transaction as the account and as whatever
  the application records about it — `docs/design.md` decision 4 says why. So this library hands over
  the pieces rather than running them, and the application appends its own steps:

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:account, MyApp.Accounts.User.changeset(%User{}, attrs))
      |> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
      |> Ecto.Multi.insert(:membership, fn %{account: account} -> … end)
      |> MyApp.Repo.transaction()

  """

  alias Ecto.Multi
  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.Identity.Steps

  @doc """
  Appends the passkey and the recovery codes to a multi that already creates the account.

  Adds two steps: `:passkey`, the credential from `Ithibati.Identity.Passkeys.key_attrs/2`, and
  `:recovery_codes`, whose result is the plaintext batch. The rows hold digests, so this result is
  the only place the batch exists.

  `:account` names the step that created the account and defaults to `:account`. `:count` says how
  many recovery codes to issue; `0` issues none. The account's existing codes, if it somehow has
  any, are replaced rather than added to.

  > #### The batch outlives a failed transaction {: .warning}
  >
  > A later step failing hands you `{:error, name, value, changes_so_far}`, and `changes_so_far`
  > still carries the plaintext codes of an account that was rolled back. Do not log that tuple
  > whole.
  """
  def with_key_and_codes(multi, key_attrs, opts \\ []) do
    multi
    |> Multi.insert(:passkey, fn changes ->
      Passkeys.credential_changeset(key_attrs, Steps.account!(changes, opts))
    end)
    # The repo the step is handed rather than `Config.repo()`. Both would write inside this
    # transaction — Ecto finds the open connection through the calling process, which is why a
    # `Repo.insert` inside `Repo.transaction` joins it — but only the passed one follows a caller
    # who has moved the repo with `put_dynamic_repo/1`, and that is a caller this library cannot
    # see. No test here can tell the two apart, so the reason is written down rather than claimed
    # by a green run.
    |> Multi.run(:recovery_codes, fn repo, changes ->
      {:ok, RecoveryCodes.issue!(repo, Steps.account!(changes, opts), opts)}
    end)
  end
end
