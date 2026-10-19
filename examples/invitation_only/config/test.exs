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

# The browser tests drive a real browser, so the server is up during `mix test`.
# `PORT` overrides the default port, as in `config/dev.exs`.
config :ithibati_invites, IthibatiInvitesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4103")],
  secret_key_base: "Kz1lE93UVKHyWrBnppQR9okfS9k0H3N94SFFKFQLIW/OT8tstSHkzq8X/riVCJ7X",
  # Playwright drives a real browser, so the server has to be up.
  server: true

# The browser features run in Playwright's Chrome for Testing, installed by `npm ci` and
# `npx playwright install chromium` in `assets/`.
config :phoenix_test,
  otp_app: :ithibati_invites,
  endpoint: IthibatiInvitesWeb.Endpoint,
  playwright: [
    timeout: 3_000,
    # A rerun with PW_SCREENSHOT=true keeps a screenshot of each feature in `screenshots/`.
    screenshot: System.get_env("PW_SCREENSHOT", "false") in ~w(t true)
  ]

config :ithibati_invites, :sql_sandbox, true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :ithibati_invites, IthibatiInvites.Mailer, adapter: Swoosh.Adapters.Test
