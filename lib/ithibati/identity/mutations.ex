defmodule Ithibati.Identity.Mutations do
  @moduledoc false
  import Ecto.Query
  alias Ithibati.Identity.Concurrency

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
        update_locked(repo, exclude(query, :select), updates, refusal)
      end)

    outcome
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
