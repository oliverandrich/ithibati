defmodule Ithibati.AdapterQueriesTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ithibati.AdapterEntry
  alias Ithibati.AdapterRepo, as: Repo

  setup do
    Repo.delete_all(AdapterEntry)
    on_exit(fn -> Repo.delete_all(AdapterEntry) end)
    %{entry: Repo.insert!(%AdapterEntry{bytes: <<77>>})}
  end

  test "selected mutation rows are available only on PostgreSQL and SQLite", %{entry: entry} do
    query = from e in AdapterEntry, where: e.id == ^entry.id, select: e

    case Application.fetch_env!(:ithibati, :probe_adapter) do
      Ecto.Adapters.MyXQL ->
        assert_raise ArgumentError, ~r/select is not supported/, fn ->
          Repo.update_all(query, set: [consumed: true])
        end

      _returning_adapter ->
        assert {1, [%AdapterEntry{consumed: true}]} =
                 Repo.update_all(query, set: [consumed: true])
    end
  end

  test "the PostgreSQL row-lock clause is not portable" do
    query = lock(AdapterEntry, "FOR NO KEY UPDATE")

    case Application.fetch_env!(:ithibati, :probe_adapter) do
      Ecto.Adapters.Postgres ->
        assert {:ok, [_]} = Repo.transaction(fn -> Repo.all(query) end)

      Ecto.Adapters.SQLite3 ->
        assert_raise ArgumentError, ~r/lock/i, fn -> Repo.to_sql(:all, query) end

      Ecto.Adapters.MyXQL ->
        assert_raise MyXQL.Error, ~r/syntax/, fn -> Repo.all(query) end
    end
  end

  test "selecting a joined row during an update is not portable", %{entry: entry} do
    other = Repo.insert!(%AdapterEntry{bytes: <<88>>})

    query =
      from e in AdapterEntry,
        join: other in AdapterEntry,
        on: other.id == ^other.id,
        where: e.id == ^entry.id,
        select: other.bytes

    case Application.fetch_env!(:ithibati, :probe_adapter) do
      Ecto.Adapters.Postgres ->
        assert {1, [<<88>>]} = Repo.update_all(query, set: [consumed: true])

      Ecto.Adapters.MyXQL ->
        assert_raise ArgumentError, ~r/select is not supported/, fn ->
          Repo.update_all(query, set: [consumed: true])
        end

      Ecto.Adapters.SQLite3 ->
        # SQLite's adapter drops RETURNING qualifiers, so this reads the target row instead.
        assert {1, [<<77>>]} = Repo.update_all(query, set: [consumed: true])
    end
  end
end
