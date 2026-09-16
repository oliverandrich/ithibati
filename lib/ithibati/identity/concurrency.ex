defmodule Ithibati.Identity.Concurrency do
  @moduledoc false

  # How this library makes a change that still has to be right when two people make it at once, in
  # one place because it is one argument. Sibling of `Ithibati.Identity.Secrets`, and there for the
  # same reason: a second copy of an argument is the copy that stops agreeing with the first.

  import Ecto.Query, only: [lock: 2, select: 3, where: 3]

  alias Ithibati.Config

  @doc """
  Makes concurrent writers to these rows queue behind each other. Compose it into the *reading*
  query of a guard-then-write, inside a transaction. Outside one, the lock is released at the
  implicit commit and buys nothing.

  It exists because a predicate carried in the `WHERE` of the update is enough only while both
  writers aim at the **same** row. The second writer then waits on that row and
  re-evaluates its condition against what the first committed. Writers aiming at different rows wait
  on nothing, and both snapshots still hold the sibling. An invariant over a *set* ("at least one of
  these must remain") therefore needs something shared to queue on. Here that is always the account
  row, which every writer to a set of its credentials wants — `lock_account!/1` takes it by id,
  and `lock_rows/1` takes it on a query that has already found the account. Postgres re-checks a locked row against the
  `WHERE` after the wait and drops it when it no longer matches, so the locking query is a reliable
  count of the rows that *survived* the writers it queued behind. It is not a count of every
  matching row: a row inserted and committed after this statement's snapshot is invisible to it, and
  no lock makes it visible. That errs the safe way for a guard of the "at least one must remain"
  shape, because a row it cannot see is a row it does not count on.

  `FOR NO KEY UPDATE`, not `FOR UPDATE`: it conflicts with itself, which is all the queueing
  needs, and not with the `FOR KEY SHARE` a foreign-key insert takes. Locking an account therefore
  does not block somebody writing a row that points at it.

  A third shape needs no lock at all. Where the invariant is over the *whole table* and not over
  a set belonging to somebody, a unique index decides, and the loser comes back as a constraint
  error and not as a row count. `Ithibati.Identity.Instance.claim/2` is that one: at most one
  instance may be claimed, so `ithibati_bootstrap` carries an index that permits a single row, and
  nothing is read beforehand.
  """
  def lock_rows(query), do: lock(query, "FOR NO KEY UPDATE")

  @doc """
  Takes the account's row, so that everything deciding about a set of its credentials queues here.

  It raises instead of answering `nil` for an account that is not there. An invariant rests on this
  lock, and losing it quietly is worse than losing it loudly.

  Nothing needs the row itself, only the lock, so the query selects a constant.
  """
  def lock_account!(id) do
    Config.user_schema()
    |> where([account], account.id == ^id)
    |> select([_account], 1)
    |> lock_rows()
    |> Config.repo().one!()
  end

  @doc """
  Whether a unique index is what refused this changeset, on the field named.

  It answers the same question as `one_affected/2` from the other side. `one_affected/2` reads a
  lost race off a row count, and this reads one off a unique index's refusal.

  Asked in one place because three callers need the same answer, and because the check is easy
  to get subtly wrong: whether `:constraint` has to say `:unique` is the part that differs
  between plausible spellings of it.
  """
  def collided?(%Ecto.Changeset{errors: errors}, field) do
    errors
    |> Keyword.get_values(field)
    |> Enum.any?(fn {_message, opts} -> opts[:constraint] == :unique end)
  end

  @doc """
  Reads the outcome off a write that carried `select:`. It answers `{:ok, row}`, or
  `{:error, refusal}` when the write matched no row.

  It belongs beside the lock because it is part of the same argument. A guard that rides the `WHERE`
  of its own statement has no separate answer to read, so the affected-row count is how it reports.

  Ithibati writes through a query instead of handing `Repo.update/1` or `Repo.delete/1` a loaded
  struct. `delete/1` raises `Ecto.StaleEntryError` for a row that is already gone, and `update/1`
  skips the database altogether when the struct already holds the value being written, reporting
  success over a row it never touched. Both are the wrong answer where the caller has to say what
  happened. Writing through the query and reading its count says what happened without a second
  statement that could disagree with the first.

  It works unchanged with the repo an `Ecto.Multi.run/3` callback hands in.
  """
  def one_affected({1, [row]}, _refusal), do: {:ok, row}
  def one_affected({0, _none}, refusal), do: {:error, refusal}
end
