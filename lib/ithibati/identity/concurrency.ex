defmodule Ithibati.Identity.Concurrency do
  @moduledoc false

  # Account locks serialize changes whose invariant spans several credential rows.

  import Ecto.Query, only: [lock: 2, select: 3, where: 3]

  alias Ithibati.Config

  @doc """
  Adds `FOR NO KEY UPDATE` to a query. Execute it inside a transaction so the lock
  remains held through the write.

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
  def lock_rows(query), do: lock(query, "FOR NO KEY UPDATE")

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
