defmodule Ithibati.Identity.Mutations do
  @moduledoc false
  import Ecto.Query
  alias Ithibati.Identity.Concurrency

  @doc """
  Updates a query matching at most one row, selected as its complete schema struct.

  Callers must constrain it by a primary key or unique key. Multiple matches violate this
  internal contract and raise, rather than returning a normal refusal. MySQL starts a prepared
  identity transaction; other adapters use a single UPDATE with RETURNING.
  """
  # MySQL has no mutation RETURNING. Keep the selected row locked through the write
  # and read its new values by primary key, since the update may invalidate its predicate.
  def update_one(repo, query, updates, refusal) do
    if repo.__adapter__() == Ecto.Adapters.MyXQL do
      mysql_update_one(repo, query, updates, refusal)
    else
      repo.update_all(query, updates) |> Concurrency.one_affected(refusal)
    end
  end

  defp mysql_update_one(repo, query, updates, refusal) do
    {:ok, outcome} =
      Concurrency.transaction(repo, fn ->
        update_one_in_transaction(repo, query, updates, refusal)
      end)

    outcome
  end

  @doc """
  Updates at most one row inside an identity transaction already prepared by `Concurrency`.

  Has the same unique-key and full-row selection contract as `update_one/4`. Performs no
  transaction preparation or isolation check; use `update_one/4` at an unprepared entry point,
  including from a caller-owned Ecto transaction. Database errors propagate without retries.
  """
  def update_one_in_transaction(repo, query, updates, refusal) do
    repo.in_transaction?() || raise ArgumentError, "a prepared identity transaction is required"

    if repo.__adapter__() == Ecto.Adapters.MyXQL do
      update_locked(repo, exclude(query, :select), updates, refusal)
    else
      repo.update_all(query, updates) |> Concurrency.one_affected(refusal)
    end
  end

  defp update_locked(repo, query, updates, refusal) do
    with row when not is_nil(row) <- repo.one(lock(query, "FOR UPDATE")),
         {1, _} <- repo.update_all(query, updates) do
      {:ok,
       repo.one!(from(r in row.__struct__, where: ^Ecto.primary_key!(row), lock: "FOR UPDATE"))}
    else
      _absent -> {:error, refusal}
    end
  end

  @doc """
  Deletes at most one uniquely identified row inside a prepared identity transaction.

  The query must select the complete schema struct. Multiple matches violate the internal
  contract and must not be treated as a normal refusal. Returns the affected count and rows.
  """
  def delete_one(repo, query) do
    if repo.__adapter__() == Ecto.Adapters.MyXQL do
      plain = exclude(query, :select)

      with row when not is_nil(row) <- repo.one(lock(plain, "FOR UPDATE")),
           {1, _} <- repo.delete_all(plain) do
        {1, [row]}
      else
        _absent -> {0, []}
      end
    else
      repo.delete_all(query)
    end
  end
end
