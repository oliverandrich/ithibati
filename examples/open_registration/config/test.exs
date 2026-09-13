import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ithibati_open, IthibatiOpen.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ithibati_open_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# `PORT` mirrors what `config/dev.exs` already does, because the browser tests under `e2e/` run both
# examples at once and neither can keep a hardcoded port. What turns the server on there is
# `PHX_SERVER`, which `config/runtime.exs` reads for every environment — so `server: false` stays
# the answer here and nothing needs to repeat that decision.
config :ithibati_open, IthibatiOpenWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4002")],
  secret_key_base: "Kz1lE93UVKHyWrBnppQR9okfS9k0H3N94SFFKFQLIW/OT8tstSHkzq8X/riVCJ7X",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
