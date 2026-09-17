defmodule Ithibati.Identity.Concurrency do
  @moduledoc false

  # Account locks serialize changes whose invariant spans several credential rows.

  import Ecto.Query, only: [from: 2, lock: 2, select: 3, where: 3]

  alias Ithibati.Config

  @doc "Starts credential transactions, reserving SQLite writes and checking MySQL isolation."
  def transaction(repo, fun) do
    opts = if repo.__adapter__() == Ecto.Adapters.SQLite3, do: [mode: :immediate], else: []

    repo.transaction(
      fn ->
        validate_transaction!(repo)
        fun.()
      end,
      opts
    )
  end

  @doc """
  Serializes credential decisions inside a transaction. PostgreSQL locks the account
  with `FOR NO KEY UPDATE`; MySQL uses `FOR UPDATE` and requires READ COMMITTED. SQLite
  reserves the database writer before reading the account,
  including inside caller-owned transactions. A stale SQLite snapshot raises before decisions;
  callers must restart the entire transaction if they choose to retry.

  The lock remains held through the outermost transaction.

  A write's `WHERE` condition protects a single row. Decisions across several rows,
  such as retaining at least one passkey, require all writers to lock a shared account
  row first. After acquiring that lock, use a separate statement to read credentials:
  under READ COMMITTED it gets a fresh snapshot that includes preceding commits.

  The locking statement itself does not see rows inserted after its snapshot. Postgres
  rechecks an existing row's condition after waiting, but the lock does not refresh the
  whole snapshot.

  `FOR NO KEY UPDATE` conflicts with itself without blocking the `FOR KEY SHARE` lock
  taken by foreign-key inserts. Table-wide uniqueness, such as the single bootstrap
  claim, is enforced by a unique index instead.
  """
  def lock_rows(query) do
    repo = Config.repo()

    case repo.__adapter__() do
      Ecto.Adapters.SQLite3 ->
        write_lock!(repo)
        query

      Ecto.Adapters.MyXQL ->
        validate_transaction!(repo)
        lock(query, "FOR UPDATE")

      _row_locking_adapter ->
        lock(query, "FOR NO KEY UPDATE")
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
  Locks the account row by id within the current transaction.

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
