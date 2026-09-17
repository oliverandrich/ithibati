defmodule Ithibati.AdapterTransactionsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ithibati.AdapterEntry
  alias Ithibati.AdapterRepo, as: Repo

  setup do
    Repo.delete_all(AdapterEntry)
    on_exit(fn -> Repo.delete_all(AdapterEntry) end)
    entry = Repo.insert!(%AdapterEntry{bytes: <<42>>})
    %{entry: entry}
  end

  test "two checked-out connections overlap and only one consumes the row", %{entry: entry} do
    parent = self()

    workers =
      for _ <- 1..2 do
        Task.async(fn ->
          Repo.checkout(fn ->
            connection = connection_id()
            send(parent, {:ready, self(), connection})

            receive do
              :consume ->
                try do
                  Ithibati.AdapterProbe.consume(entry.id)
                after
                  if Application.fetch_env!(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3,
                    do: Repo.query!("DROP TABLE adapter_connection_probe")
                end
            after
              2_000 -> raise "consume barrier timed out"
            end
          end)
        end)
      end

    try do
      assert_receive {:ready, first, first_connection}, 2_000
      assert_receive {:ready, second, second_connection}, 2_000
      assert first_connection != second_connection
      send(first, :consume)
      send(second, :consume)
      assert workers |> Enum.map(&Task.await(&1, 3_000)) |> Enum.sort() == [{0, nil}, {1, nil}]
    after
      Enum.each(workers, &Task.shutdown(&1, :brutal_kill))
    end
  end

  test "an earlier read observes the backend's default transaction isolation", %{entry: entry} do
    adapter = Application.fetch_env!(:ithibati, :probe_adapter)

    assert {:ok, visible} =
             Repo.transaction(fn ->
               refute Repo.get!(AdapterEntry, entry.id).consumed
               commit_elsewhere(entry)
               Repo.get!(AdapterEntry, entry.id).consumed
             end)

    assert visible == (adapter == Ecto.Adapters.Postgres)
  end

  test "a nested transaction cannot refresh an existing snapshot", %{entry: entry} do
    assert {:ok, {:ok, visible}} =
             Repo.transaction(fn ->
               refute Repo.get!(AdapterEntry, entry.id).consumed
               commit_elsewhere(entry)
               Repo.transaction(fn -> Repo.get!(AdapterEntry, entry.id).consumed end)
             end)

    assert visible ==
             (Application.fetch_env!(:ithibati, :probe_adapter) == Ecto.Adapters.Postgres)
  end

  if Application.compile_env!(:ithibati, :probe_adapter) == Ecto.Adapters.MyXQL do
    test "READ COMMITTED refreshes even a caller-owned transaction", %{entry: entry} do
      Repo.checkout(fn ->
        Repo.query!("SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED")

        try do
          assert {:ok, {:ok, true}} =
                   Repo.transaction(fn ->
                     refute Repo.get!(AdapterEntry, entry.id).consumed
                     commit_elsewhere(entry)
                     Repo.transaction(fn -> Repo.get!(AdapterEntry, entry.id).consumed end)
                   end)
        after
          Repo.query!("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        end
      end)
    end
  end

  if Application.compile_env!(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3 do
    @tag capture_log: true
    test "an immediate writer excludes another writer", %{entry: entry} do
      assert {:ok, :held} =
               Repo.transaction(
                 fn ->
                   task =
                     Task.async(fn ->
                       assert_raise Exqlite.Error, ~r/database is locked/, fn ->
                         Repo.transaction(fn -> :second_writer end, mode: :immediate)
                       end
                     end)

                   assert %Exqlite.Error{} = Task.await(task, 3_000)
                   refute Repo.get!(AdapterEntry, entry.id).consumed
                   :held
                 end,
                 mode: :immediate
               )
    end

    test "a nested immediate request does not upgrade an outer deferred snapshot", %{entry: entry} do
      assert_raise Exqlite.Error, ~r/Database busy|database is locked|Database is busy/, fn ->
        Repo.transaction(fn ->
          refute Repo.get!(AdapterEntry, entry.id).consumed
          commit_elsewhere(entry)

          Repo.transaction(
            fn ->
              Repo.update_all(from(e in AdapterEntry, where: e.id == ^entry.id),
                set: [consumed: true]
              )
            end,
            mode: :immediate
          )
        end)
      end

      assert Repo.get!(AdapterEntry, entry.id).consumed
    end
  end

  defp commit_elsewhere(entry) do
    task =
      Task.async(fn ->
        Repo.update_all(from(e in AdapterEntry, where: e.id == ^entry.id), set: [consumed: true])
      end)

    assert {1, nil} = Task.await(task, 3_000)
  end

  defp connection_id do
    case Application.fetch_env!(:ithibati, :probe_adapter) do
      Ecto.Adapters.Postgres ->
        Repo.query!("SELECT pg_backend_pid()").rows

      Ecto.Adapters.MyXQL ->
        Repo.query!("SELECT CONNECTION_ID()").rows

      Ecto.Adapters.SQLite3 ->
        # The same temporary-table name would collide if both workers shared a connection.
        Repo.query!("CREATE TEMP TABLE adapter_connection_probe (id INTEGER)")
        self()
    end
  end
end
