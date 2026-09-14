import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ithibati_invites, IthibatiInvites.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ithibati_invites_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# The browser tests drive a real Chrome, so the server is up during `mix test` — which also means
# this port is bound, where it used to be inert. The two examples therefore default to different
# ones, so their suites can run at the same time; `PORT` still overrides, the way `config/dev.exs`
# already allows.
config :ithibati_invites, IthibatiInvitesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4103")],
  secret_key_base: "Kz1lE93UVKHyWrBnppQR9okfS9k0H3N94SFFKFQLIW/OT8tstSHkzq8X/riVCJ7X",
  # Wallaby drives a real browser, so the server has to be up.
  server: true

# The driver's path is worked out at run time in `test/test_helper.exs`: its version has to match
# the Chrome on this machine, so it is not pinned anywhere tracked, and CI has one of its own.
config :wallaby,
  otp_app: :ithibati_invites,
  driver: Wallaby.Chrome,
  # LiveView is chatty on the console and Wallaby echoes all of it into the test output.
  js_logger: nil,
  # A red browser test is otherwise unreadable: the message names a selector and nothing about the
  # page it failed against.
  screenshot_on_failure: true

config :ithibati_invites, :sql_sandbox, true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
