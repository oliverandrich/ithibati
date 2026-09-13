defmodule Ithibati.Identity.Concurrency do
  @moduledoc false

  # How this library makes a change that still has to be right when two people make it at once, in
  # one place because it is one argument. Sibling of `Ithibati.Identity.Secrets`, and there for the
  # same reason: a second copy of an argument is the copy that stops agreeing with the first.

  import Ecto.Query, only: [lock: 2, select: 3, where: 3]

  alias Ithibati.Config

  @doc """
  Makes concurrent writers to these rows queue behind each other. Compose it into the *reading*
  query of a guard-then-write, inside a transaction — outside one the lock is released at the
  implicit commit and buys nothing.

  It exists because `docs/design.md` decision 8's predicate-in-the-`WHERE` is enough only while both
  writers aim at the **same** row: then the second waits on that row and re-evaluates its condition
  against what the first committed. Aiming at different rows, neither waits and both snapshots still
  hold the sibling — so an invariant over a *set* ("at least one of these must remain") needs
  something shared to queue on. Here that is always the account row, which is the one thing every
  writer to a set of its credentials wants — `lock_account!/1` is the only way this library takes
  such a lock, so that stays true. Postgres re-checks a locked row against the `WHERE`
  after the wait and drops it when it no longer matches, so the locking query is a reliable count of
  the rows that *survived* the writers it queued behind. It is not a count of every matching row: one
  inserted and committed after this statement's snapshot is invisible to it, and no lock makes it
  visible. For a guard of the "at least one must remain" shape that errs the safe way — a row it
  cannot see is one it does not count on.

  `FOR NO KEY UPDATE` rather than `FOR UPDATE`: it conflicts with itself, which is all the queueing
  needs, but not with the `FOR KEY SHARE` a foreign-key insert takes — locking an account therefore
  does not block somebody writing a row that points at it.
  """
  def lock_rows(query), do: lock(query, "FOR NO KEY UPDATE")

  @doc """
  Takes the account's row, so that everything deciding about a set of its credentials queues here.

  Raises rather than answering `nil` for an account that is not there: what rests on this lock is an
  invariant, and losing it quietly is worse than losing it loudly.

  The row itself is never wanted — only the lock — so it selects a constant.
  """
  def lock_account!(id) do
    Config.user_schema()
    |> where([account], account.id == ^id)
    |> select([_account], 1)
    |> lock_rows()
    |> Config.repo().one!()
  end

  @doc """
  Reads the outcome off a write that carried `select:` — `{:ok, row}`, or `{:error, refusal}` when
  it matched none.

  It belongs beside the lock because it is the other half of the same argument: a guard that rides
  the `WHERE` of its own statement has no separate answer to read, so the affected-row count *is* how
  it reports.

  Why this library writes through a query rather than handing `Repo.update/1` or `Repo.delete/1` a
  loaded struct: `delete/1` raises `Ecto.StaleEntryError` for a row that is already gone, and
  `update/1` skips the database altogether when the struct already holds the value being written,
  reporting success over a row it never touched. Both are the wrong answer where the caller has to
  say what happened. Writing through the query and reading its count says it without a second
  statement that could disagree with the first.

  Works unchanged with the repo an `Ecto.Multi.run/3` callback hands in.
  """
  def one_affected({1, [row]}, _refusal), do: {:ok, row}
  def one_affected({0, _none}, refusal), do: {:error, refusal}
end
