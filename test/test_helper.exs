# Credo caches parsed ASTs in a GenServer, so a test that parses a source needs its application up,
# and `runtime: false` means nothing starts it for us. The result is deliberately not matched: under
# `mix precommit`, `mix credo` has already run in this VM and left the application stopped with its
# supervisor alive, and `ensure_all_started/1` then returns an error tuple rather than `{:ok, []}`.
# Measured in both directions — matching on `{:ok, _}` turns the gate red while a bare `mix test`
# stays green, and dropping the call entirely does the exact opposite.
_ = Application.ensure_all_started(:credo)

# The database is created and migrated here rather than by `mix ecto.create`/`ecto.migrate`, so that
# a plain `mix test` is the whole setup. The path is passed explicitly because `Ecto.Migrator`
# resolves the repo's `:priv` against `_build`, where only `priv/` is linked.
repo = Ithibati.TestRepo
migrations = Path.expand("support/migrations", __DIR__)
config = repo.config()

# A migration directory that is missing *or empty* is not an error to `Ecto.Migrator` — it finds no
# files and returns `[]`, so against a database that already exists the suite stays green while
# nothing is ever applied again.
Path.wildcard(Path.join(migrations, "*.exs")) == [] && raise("no migrations at #{migrations}")

case repo.__adapter__().storage_up(config) do
  :ok ->
    :ok

  {:error, :already_up} ->
    :ok

  {:error, reason} ->
    raise "could not reach #{config[:hostname]}:#{config[:port]} as #{config[:username]}: " <>
            inspect(reason)
end

{:ok, _pid} = repo.start_link()
Ecto.Migrator.run(repo, migrations, :up, all: true, log: false)
Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)

# Started here rather than in a `setup_all`: the endpoint's supervisor is registered under the
# module name, so a second `async: true` module doing the same would collide — as a flake, in
# whichever module happened to lose the race. It serves nothing (`server: false`); the ceremony
# tests want it only for the configured URL its relying party comes from.
if Code.ensure_loaded?(Ithibati.TestEndpoint), do: {:ok, _} = Ithibati.TestEndpoint.start_link()

ExUnit.start()
