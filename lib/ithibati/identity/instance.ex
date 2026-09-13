defmodule Ithibati.Identity.Instance do
  @moduledoc """
  Setting a deployment up: the first account, and the record that it happened.

  A self-hosted instance starts empty, and on an invitation-only one somebody has to become the
  first account without an invitation from anyone — there is nobody to write one yet. This is the
  way in that needs no one already inside, and it may be taken exactly once.

  What makes it once is `Ithibati.Bootstrap`'s row and the unique index the migration puts on it,
  not a count read beforehand; `claim/2` says how.

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:account, MyApp.Accounts.User.changeset(%User{}, %{email: email}))
      |> Ithibati.Identity.Instance.claim()
      |> Ithibati.Identity.Grant.with_key_and_codes(key_attrs)
      |> MyApp.Repo.transaction()

  Before the grant rather than after it: a refused claim then never mints the recovery codes, which
  `Ithibati.Identity.Grant.with_key_and_codes/3` warns would otherwise sit in plaintext in the
  `changes_so_far` of a transaction that rolled back.

  Named for the deployment rather than for the table, because that is what both functions are about
  and what an application asks them. The *step* `claim/2` adds is named for the row, `:bootstrap`,
  the way `:invitation` and `:passkey` are — a step name is what an application matches on, and what
  it holds is that row.
  """

  alias Ecto.Multi
  alias Ithibati.Bootstrap
  alias Ithibati.Config
  alias Ithibati.Identity.Steps

  @doc """
  Whether this deployment has been claimed yet.

  The question a setup page asks, and it answers about the claim rather than about accounts: an
  application that never composes `claim/2` — one with open registration — is never claimed, however
  many accounts it has.

  It is *not* the question `Ithibati.Identity.Passkeys.authentication_challenge/3` answers with
  `{:error, :no_credentials}`, and the two can disagree: an account that signs in by recovery code
  after revoking its last passkey leaves an instance that is claimed and has no credentials. Which
  of the two a sign-in page should act on is the application's to decide, which is why this library
  answers both and folds neither into the other.

  Answered from the row rather than from the accounts table: the row outlives the account that made
  it, so deleting whoever set the instance up leaves a second claim refused by the unique index just
  as before.
  """
  def needs_setup?, do: not Config.repo().exists?(Bootstrap)

  @doc """
  Claims the instance for the account this transaction is creating, as a step named `:bootstrap`.

  `{:error, :already_claimed}` when somebody got there first, which rolls the whole transaction
  back — so the account, its first passkey and its recovery codes go with it, and a registration
  page that composes this is a one-time page rather than one that warns.

  Anything else the insert refuses comes back as `{:error, %Ecto.Changeset{}}` under the same step
  name — a `user_id` the accounts table does not hold trips the foreign key, which is what happens
  when that account is deleted by a concurrent transaction between the two inserts. A caller
  matching only on `:already_claimed` would meet a `CaseClauseError` on a registration page.

  `account:` names the step the account comes from and defaults to `:account`, the name every
  fragment in this library uses. Unlike `Ithibati.Identity.Invitations.accept/3` this one cannot be
  composed without such a step: the row records *who* set the instance up.
  """
  def claim(multi, opts \\ []) do
    # No `exists?` before the insert: the unique index is the guarantee, and a read could not decide
    # anything it does not already decide. What such a read buys elsewhere — not doing the work when
    # somebody else has won — is not available here, because the account insert is already behind us
    # and rolls back with this refusal either way. `Ithibati.Identity.Concurrency` sets out the three
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
