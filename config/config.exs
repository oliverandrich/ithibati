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

  # The account key type is compiled into the schemas, so one compilation exercises exactly one of
  # them and the other is reachable only by building again. A CI leg sets this; a laptop gets the
  # default, which is also the default a consumer gets.
  #
  # An unknown value raises rather than falling back: a typo in the matrix would otherwise turn the
  # leg that exists to exercise integer keys into an exact copy of the default one — green, and
  # saying nothing at all.
  key_type =
    case env.("ITHIBATI_USERS_KEY_TYPE", "binary_id") do
      "binary_id" -> :binary_id
      "id" -> :id
      other -> raise "ITHIBATI_USERS_KEY_TYPE must be binary_id or id, got: #{inspect(other)}"
    end

  config :ithibati,
    ecto_repos: [Ithibati.TestRepo],
    user_schema: Ithibati.TestUser,
    invitation_schema: Ithibati.TestInvitation,
    users_key_type: key_type,
    repo: Ithibati.TestRepo,
    # Two contexts beyond the built-in "session", so the token tests can prove that validity is
    # resolved per context and that the unit is read — without moving application environment,
    # which would cost them their `async: true`.
    token_validity: %{"device" => {90, :day}, "brief" => {5, :second}}

  config :ithibati, Ithibati.TestRepo,
    username: env.("PGUSER", "postgres"),
    # The deliberate exception to the rule above: an empty password is meaningful, and a
    # trust-authenticated local role is set up exactly that way.
    password: System.get_env("PGPASSWORD", "postgres"),
    hostname: env.("PGHOST", "localhost"),
    port: String.to_integer(env.("PGPORT", "5432")),
    # The key type is part of the name for the same reason it is part of CI's cache key: the two
    # builds want different column types, and a run that finds a database already there treats it as
    # ready. Switching the type without dropping the database would otherwise fail as cast errors
    # that look like a bug in this library.
    database:
      "ithibati_test#{System.get_env("MIX_TEST_PARTITION")}#{if key_type == :id, do: "_int"}",
    pool: Ecto.Adapters.SQL.Sandbox,
    # A floor, not just a multiple of the core count: the suite drives concurrent writes to prove a
    # unique index decides between them, and on a machine with fewer cores those racers would queue
    # instead of racing. `Ithibati.BootstrapTest` asserts the pool is big enough rather than passing
    # quietly as a sequence — which is how CI found this.
    pool_size: max(System.schedulers_online() * 2, 12),
    # Read by `mix ecto.*` alone, which resolves it against the source tree; the suite passes its
    # path explicitly instead. Without this key `mix ecto.gen.migration` would create a `priv/`
    # directory, and `priv/` is what gets published to consumers.
    priv: "test/support"

  config :logger, level: :warning
end
