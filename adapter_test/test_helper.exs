ExUnit.start()

repo = Ithibati.AdapterRepo

case repo.__adapter__().storage_up(repo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
  {:error, reason} -> raise "adapter probe database unavailable: #{inspect(reason)}"
end

{:ok, _} = repo.start_link()
Ecto.Migrator.up(repo, 1, Ithibati.AdapterMigration, log: false)
Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)

version_query =
  case repo.__adapter__() do
    Ecto.Adapters.SQLite3 -> "SELECT sqlite_version()"
    _server -> "SELECT version()"
  end

[[version]] = repo.query!(version_query).rows
IO.puts("Adapter probe engine: #{version}")

if repo.__adapter__() == Ecto.Adapters.SQLite3 do
  Code.require_file("../test/support/test_credentials.ex", __DIR__)
end
