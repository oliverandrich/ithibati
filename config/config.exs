import Config

# A library has no configuration of its own — a consumer configures the repo it wants used. What is
# here exists only so this project can run its own tests, and a consumer never reads it: Mix loads
# the top-level application's `config/`, never a dependency's.
if config_env() == :test do
  # `export PGHOST=` is how a shell unsets a variable in practice, and `System.get_env/2` returns its
  # default only for a name that is *absent* — an empty value would otherwise mean an empty hostname.
  env = fn name, default ->
    case System.get_env(name) do
      value when value in [nil, ""] -> default
      value -> value
    end
  end

  config :ithibati, ecto_repos: [Ithibati.TestRepo]

  config :ithibati, Ithibati.TestRepo,
    username: env.("PGUSER", "postgres"),
    # The deliberate exception to the rule above: an empty password is meaningful, and a
    # trust-authenticated local role is set up exactly that way.
    password: System.get_env("PGPASSWORD", "postgres"),
    hostname: env.("PGHOST", "localhost"),
    port: String.to_integer(env.("PGPORT", "5432")),
    database: "ithibati_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2,
    # Read by `mix ecto.*` alone, which resolves it against the source tree; the suite passes its
    # path explicitly instead. Without this key `mix ecto.gen.migration` would create a `priv/`
    # directory, and `priv/` is what gets published to consumers.
    priv: "test/support"

  config :logger, level: :warning
end
