defmodule Ithibati.Identity.Grant do
  @moduledoc """
  The credential half of creating an account, as a fragment the application composes into its own
  transaction.

  The passkey and the recovery codes belong in the same transaction as the account and as whatever
  the application records about it. Ithibati therefore
  hands over the pieces without running them, and the application appends its own steps:

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:account, MyApp.Accounts.User.changeset(%User{}, attrs))
      |> Ecto.Multi.insert(:membership, fn %{account: account} -> … end)
      |> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
      |> MyApp.Repo.transaction()

  """

  alias Ecto.Multi
  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.Identity.Steps

  @doc """
  Appends the passkey and the recovery codes to a multi that already creates the account.

  It adds two steps: `:passkey`, the credential from `Ithibati.Identity.Passkeys.key_attrs/2`, and
  `:recovery_codes`, whose result is the plaintext batch. The rows hold digests, so this result is
  the only place the batch exists.

  `:account` names the step that created the account and defaults to `:account`. `:count` says how
  many recovery codes to issue, and `0` issues none. Ithibati replaces the account's existing codes,
  if it somehow has any, instead of adding to them.

  > #### The batch outlives a failed transaction {: .warning}
  >
  > A later step failing hands you `{:error, name, value, changes_so_far}`, and `changes_so_far`
  > still carries the plaintext codes of an account that was rolled back. Do not log that tuple
  > whole. Compose whatever can refuse *before* this step and not after it, so a transaction
  > that was never going to commit does not mint a batch on its way to being rolled back.
  > `Ithibati.Identity.Instance.claim/2` and `Ithibati.Identity.Invitations.accept/3` are both such
  > steps.
  """
  def with_key_and_codes(multi, key_attrs, opts \\ []) do
    multi
    |> Multi.insert(:passkey, fn changes ->
      Passkeys.credential_changeset(key_attrs, Steps.account!(changes, opts))
    end)
    # The repo the step is handed, not `Config.repo()`. Both would write inside this
    # transaction. Ecto finds the open connection through the calling process, which is why a
    # `Repo.insert` inside `Repo.transaction` joins it. But only the passed one follows a caller
    # who has moved the repo with `put_dynamic_repo/1`, and that is a caller this library cannot
    # see. No test here can tell the two apart, so the reason is written down and not claimed
    # by a green run.
    |> Multi.run(:recovery_codes, fn repo, changes ->
      {:ok, RecoveryCodes.issue!(repo, Steps.account!(changes, opts), opts)}
    end)
  end
end
