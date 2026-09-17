if Application.compile_env!(:ithibati, :probe_adapter) == Ecto.Adapters.SQLite3 do
  defmodule Ithibati.SQLiteCase do
    @moduledoc false
    use ExUnit.CaseTemplate
    alias Ithibati.AdapterRepo, as: Repo
    alias Ithibati.Identity.Passkeys

    using do
      quote do
        alias Ithibati.AdapterRepo, as: Repo
        alias Ithibati.SQLiteInvitation, as: Invitation
        alias Ithibati.SQLiteUser, as: User
        import Ithibati.SQLiteCase
      end
    end

    setup do
      for {key, value} <- [
            repo: Repo,
            user_schema: Ithibati.SQLiteUser,
            invitation_schema: Ithibati.SQLiteInvitation
          ] do
        previous = Application.fetch_env(:ithibati, key)
        Application.put_env(:ithibati, key, value)

        on_exit(fn ->
          case previous do
            {:ok, old} -> Application.put_env(:ithibati, key, old)
            :error -> Application.delete_env(:ithibati, key)
          end
        end)
      end

      Ecto.Migrator.up(Repo, 10, Ithibati.SQLiteApplicationMigration, log: false)
      Ecto.Migrator.up(Repo, 11, Ithibati.SQLiteLibraryMigration, log: false)
      clear()
      on_exit(&clear/0)
      :ok
    end

    def user do
      Repo.insert!(%Ithibati.SQLiteUser{
        email: "user-#{System.unique_integer([:positive])}@example.test"
      })
    end

    def key(user) do
      {:ok, key} =
        Passkeys.add_key(user, %{
          key_id: :crypto.strong_rand_bytes(16),
          public_key: :erlang.term_to_binary(%{1 => 2})
        })

      key
    end

    def race(fun) do
      parent = self()

      tasks =
        for number <- 1..2 do
          Task.async(fn -> race_worker(parent, number, fun) end)
        end

      try do
        assert_receive {:ready, first}, 2_000
        assert_receive {:ready, second}, 2_000
        send(first, :run)
        send(second, :run)
        Enum.map(tasks, &Task.await(&1, 5_000))
      after
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      end
    end

    defp race_worker(parent, number, fun) do
      retry_busy(
        fn ->
          Repo.checkout(fn ->
            await_race(parent)
            fun.(number)
          end)
        end,
        3
      )
    end

    defp await_race(parent) do
      unless Process.get(:sqlite_race_started) do
        send(parent, {:ready, self()})

        receive do
          :run -> Process.put(:sqlite_race_started, true)
        after
          2_000 -> raise "SQLite race barrier timed out"
        end
      end
    end

    # These test operations have no external side effects. Retry a whole rolled-back
    # operation after SQLite contention, as a caller may; the library never replays callbacks.
    defp retry_busy(fun, remaining) do
      fun.()
    rescue
      error in Exqlite.Error ->
        if remaining > 0 and Regex.match?(~r/busy|locked/i, error.message) do
          Process.sleep(10)
          retry_busy(fun, remaining - 1)
        else
          reraise error, __STACKTRACE__
        end
    end

    defp clear do
      Repo.delete_all(Ithibati.Bootstrap)
      Repo.delete_all(Ithibati.SQLiteUser)
      Repo.delete_all(Ithibati.SQLiteInvitation)
    end
  end
end
