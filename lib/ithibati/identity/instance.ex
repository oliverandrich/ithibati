defmodule Ithibati.Identity.Instance do
  @moduledoc """
  Records the one-time claim of an instance by its first account.

  Use this for invitation-only registration, where the first account has nobody to invite it.
  The bootstrap row and its unique index enforce a single claim, including concurrent attempts.
  Open-registration applications need not use it.

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

  alias Ecto.Multi
  alias Ithibati.Bootstrap
  alias Ithibati.Config
  alias Ithibati.Identity.Steps

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

  @doc """
  Appends a `:bootstrap` step to the multi and returns the multi.

  The `:account` option names an earlier step providing the account and defaults to `:account`.
  That step is required. On success, `:bootstrap` contains the inserted `Ithibati.Bootstrap` row.

  An existing claim makes `Repo.transaction/1` return
  `{:error, :bootstrap, :already_claimed, changes_so_far}`. Other insert errors return a changeset
  as the reason under the same step name. The transaction rolls back on either failure.

  The unique index enforces this result even when callers attempt the first claim concurrently.
  """
  def claim(multi, opts \\ []) do
    # The unique index arbitrates concurrent claims. A preliminary existence check would not
    # reserve the claim and would add a query before the same insert.
    Multi.run(multi, :bootstrap, fn repo, changes ->
      account = Steps.account!(changes, opts)

      repo.insert(Bootstrap.changeset(%Bootstrap{}, %{user_id: account.id}))
      |> name_constraint()
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
