defmodule Ithibati.Identity.Concurrency do
  @moduledoc false

  # Account locks serialize changes whose invariant spans several credential rows.

  import Ecto.Query, only: [from: 2, lock: 2, select: 3, where: 3]

  alias Ithibati.Config

  @doc """
  Prepares an identity transaction before executing its callback.

  Checks MySQL isolation on the transaction's connection at every entry, including within a
  caller-owned transaction. Reserves SQLite writes before any callback reads; the explicit
  reservation also protects callers whose outer transaction began deferred. No connection
  state is cached. Callbacks are never retried.
  """
  def transaction(repo, fun) do
    opts = if repo.__adapter__() == Ecto.Adapters.SQLite3, do: [mode: :immediate], else: []

    repo.transaction(
      fn ->
        validate_transaction!(repo)
        if repo.__adapter__() == Ecto.Adapters.SQLite3, do: write_lock!(repo)
        fun.()
      end,
      opts
    )
  end

  @doc """
  Adds the adapter's row-lock clause without executing any database operations.

  Execute the returned query inside `transaction/2`, which checks MySQL isolation and reserves
  SQLite's writer before reads. SQLite needs no row-lock clause. Constructing this query does
  not acquire a lock; executing it does. Locks remain held through the outermost transaction.
  """
  def lock_rows(query) do
    case Config.repo().__adapter__() do
      Ecto.Adapters.SQLite3 -> query
      Ecto.Adapters.MyXQL -> lock(query, "FOR UPDATE")
      Ecto.Adapters.Postgres -> lock(query, "FOR NO KEY UPDATE")
    end
  end

  defp validate_transaction!(repo) do
    if repo.__adapter__() == Ecto.Adapters.MyXQL do
      repo.query!("SELECT @@transaction_isolation", [], log: false).rows == [["READ-COMMITTED"]] ||
        raise ArgumentError,
              "MySQL identity transactions require READ COMMITTED on every connection"
    end
  end

  @doc "Acquires SQLite's writer reservation without changing any rows, inside a transaction."
  def write_lock!(repo) do
    repo.in_transaction?() || raise ArgumentError, "a SQLite write lock requires a transaction"

    # An UPDATE reserves the writer even with no matching rows. Unlike BEGIN IMMEDIATE this
    # also works inside a caller's deferred transaction; a stale snapshot fails before decisions.
    repo.update_all(from(b in Ithibati.Bootstrap, where: false), set: [claimed: true])
    :ok
  end

  @doc """
  Locks the account row by id inside a transaction prepared by `transaction/2`.

  All writers of an invariant spanning credential rows must lock the account first, then read
  credentials in a separate statement to obtain a fresh READ COMMITTED snapshot. The locking
  statement itself does not see rows inserted after its snapshot. PostgreSQL uses
  `FOR NO KEY UPDATE`, which serializes these decisions without blocking foreign-key inserts;
  MySQL uses `FOR UPDATE`. SQLite already holds the writer reservation.

  Selects a constant because callers need the lock, not the account data. Raises
  `Ecto.NoResultsError` if the account no longer exists; callers must not continue
  without the lock.
  """
  def lock_account!(id) do
    Config.user_schema()
    |> where([account], account.id == ^id)
    |> select([_account], 1)
    |> lock_rows()
    |> Config.repo().one!()
  end

  @doc """
  Returns whether the changeset has a unique-constraint error on the given field.
  """
  def collided?(%Ecto.Changeset{errors: errors}, field) do
    errors
    |> Keyword.get_values(field)
    |> Enum.any?(fn {_message, opts} -> opts[:constraint] == :unique end)
  end

  @doc """
  Converts a write's affected-row count into `{:ok, row}` or `{:error, refusal}`.

  The query must select the affected row and match at most one row. Query-based writes
  report whether a row was actually changed: a struct update can skip an unchanged
  value, and deleting a stale struct raises instead of returning a refusal.
  """
  def one_affected({1, [row]}, _refusal), do: {:ok, row}
  def one_affected({0, _none}, refusal), do: {:error, refusal}
end
