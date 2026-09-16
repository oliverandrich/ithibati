defmodule Ithibati.Identity.Instance do
  @moduledoc """
  Setting a deployment up: the first account, and the record that it happened.

  A self-hosted instance starts empty. On an invitation-only one, somebody has to become the first
  account without an invitation from anyone, because there is nobody to write one yet. This module
  is the way in that needs no one already inside, and it may be taken exactly once.

  `Ithibati.Bootstrap`'s row and the unique index the migration puts on it are what make it once,
  and not a count read beforehand. `claim/2` says how.

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:account, MyApp.Accounts.User.changeset(%User{}, %{email: email}))
      |> Ithibati.Identity.Instance.claim()
      |> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
      |> MyApp.Repo.transaction()

  Claim before the grant, not after it, for the reason
  `Ithibati.Identity.Grant.with_key_and_codes/3` warns about: this step can refuse, and a refusal
  after the grant comes when the recovery codes have already been minted.

  The module is named for the deployment, not for the table, because the deployment is what
  both functions are about and what an application asks them. The *step* `claim/2` adds is named for
  the row, `:bootstrap`, the way `:invitation` and `:passkey` are. An application matches on a step
  name, and what the step holds is that row.
  """

  alias Ecto.Multi
  alias Ithibati.Bootstrap
  alias Ithibati.Config
  alias Ithibati.Identity.Steps

  @doc """
  Whether this deployment has been claimed yet.

  A setup page asks this question. It answers about the claim, not about accounts: an
  application that never composes `claim/2`, one with open registration, is never claimed, however
  many accounts it has.

  It is not the question `Ithibati.Identity.Passkeys.authentication_challenge/3` answers with
  `{:error, :no_credentials}`, and the two can disagree. An account that signs in by recovery code
  after revoking its last passkey leaves an instance that is claimed and has no credentials. The
  application decides which of the two a sign-in page should act on, which is why Ithibati answers
  both and folds neither into the other.

  The answer comes from the row, not from the accounts table. The row outlives the account
  that made it, so deleting whoever set the instance up leaves a second claim refused by the unique
  index just as before.
  """
  def needs_setup?, do: not Config.repo().exists?(Bootstrap)

  @doc """
  Claims the instance for the account this transaction is creating, as a step named `:bootstrap`.

  The step answers `{:error, :already_claimed}` when somebody got there first, and that rolls the
  whole transaction back. The account, its first passkey and its recovery codes go with it, so a
  registration page that composes this is a one-time page, not one that warns.

  Anything else the insert refuses comes back as `{:error, %Ecto.Changeset{}}` under the same step
  name. A `user_id` the accounts table does not hold trips the foreign key, which is what happens
  when a concurrent transaction deletes that account between the two inserts. A caller matching only
  on `:already_claimed` would meet a `CaseClauseError` on a registration page.

  `account:` names the step the account comes from and defaults to `:account`, the name every
  fragment in Ithibati uses. Unlike `Ithibati.Identity.Invitations.accept/3`, this one cannot be
  composed without such a step: the row records *who* set the instance up.
  """
  def claim(multi, opts \\ []) do
    # No `exists?` before the insert: the unique index is the guarantee, and a read could not decide
    # anything it does not already decide. Elsewhere such a read buys you not doing the work when
    # somebody else has won. That is not available here: the account insert is already behind us and
    # rolls back with this refusal either way. `Ithibati.Identity.Concurrency` sets out the three
    # shapes and which one this is.
    Multi.run(multi, :bootstrap, fn repo, changes ->
      account = Steps.account!(changes, opts)

      repo.insert(Bootstrap.changeset(%Bootstrap{}, %{user_id: account.id}))
      |> name_constraint()
    end)
  end

  # The loser arrives as a constraint error on `:claimed`, and gets the name a caller can match on.
  # Everything else passes through as it came.
  defp name_constraint({:ok, bootstrap}), do: {:ok, bootstrap}

  defp name_constraint({:error, changeset}) do
    if Keyword.has_key?(changeset.errors, :claimed),
      do: {:error, :already_claimed},
      else: {:error, changeset}
  end
end
