import Config

if config_env() in [:dev, :test] do
  # Preserve existing example migrations; lint subsequent deployment migrations.
  config :excellent_migrations, start_after: "20260918000000"
end

# A library has no configuration of its own — a consumer configures the repo it wants used. What is
# here exists only so this project can run its own tests, and a consumer never reads it: Mix loads
# the top-level application's `config/`, never a dependency's.
if config_env() == :test and is_nil(System.get_env("ITHIBATI_ADAPTER_PROBE")) do
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
    repo: Ithibati.TestRepo

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
    # instead of racing. `Ithibati.RaceCase.racing/2` asserts the pool holds as many connections as
    # the racers it is about to start, rather than passing quietly as a sequence — which is how CI
    # found this.
    pool_size: max(System.schedulers_online() * 2, 12),
    # Read by `mix ecto.*` alone, which resolves it against the source tree; the suite passes its
    # path explicitly instead. Without this key `mix ecto.gen.migration` would create a `priv/`
    # directory, and `priv/` is what gets published to consumers.
    priv: "test/support"

  # Only what `Phoenix.Endpoint` refuses to start without, plus the URL the ceremony reads its
  # relying party from — the one the browser sees, which behind a proxy is not the one this node
  # accepted.
  config :ithibati, Ithibati.TestEndpoint,
    url: [host: "example.test", scheme: "https", port: 443],
    secret_key_base: String.duplicate("a", 64),
    # What a `mix phx.new` application always has, and what `Ithibati.Web.Gate` needs before it will
    # name a live socket at all.
    pubsub_server: Ithibati.TestPubSub,
    # Without this the endpoint derives `Ithibati.ErrorView`, which does not exist, and every
    # exception raised inside a request is replaced by the `ArgumentError` from failing to render
    # a 500 — so a test asserting what a controller raises sees the rendering error instead.
    render_errors: [formats: [json: Ithibati.TestErrorJSON], layout: false],
    server: false

  # The other kind of consumer: Phoenix without a pubsub server. Its whole content is the key that
  # is *missing* — no URL and no secret, because nothing is dispatched through this endpoint and a
  # second copy of those would bury the one line that makes it different.
  config :ithibati, Ithibati.TestEndpointWithoutPubSub, server: false

  config :logger, level: :warning
end

if config_env() == :test and System.get_env("ITHIBATI_ADAPTER_PROBE") do
  import_config "adapter_probe.exs"
end
