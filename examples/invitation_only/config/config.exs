# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Ithibati is told which repo and which account schema are yours; it does not guess. The key type
# has to match what this application's `users.id` actually is — Phoenix's default `bigserial` here —
# or the migration refuses rather than building a foreign key that cannot bridge the two.
config :ithibati,
  repo: IthibatiInvites.Repo,
  user_schema: IthibatiInvites.Accounts.User,
  invitation_schema: IthibatiInvites.Accounts.Invitation,
  users_key_type: :id

config :ithibati_invites,
  ecto_repos: [IthibatiInvites.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :ithibati_invites, IthibatiInvitesWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: IthibatiInvitesWeb.ErrorHTML, json: IthibatiInvitesWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: IthibatiInvites.PubSub,
  live_view: [signing_salt: "q2E9tq+P"]

# Configure esbuild (the version is required)
config :esbuild,
  # Current at the time of writing, not what `mix phx.new` happened to know. The generator pins
  # whatever it shipped with, and an example sitting on an old toolchain teaches the wrong habit.
  version: "0.28.2",
  ithibati_invites: [
    # The last alias is this example's alone. A consumer takes Ithibati from Hex, where it lands in
    # `deps/` and the bare `import … from "ithibati"` resolves through the NODE_PATH below with no
    # configuration at all. This example depends on the library by *path*, and Mix creates no
    # `deps/ithibati` for those — so the one thing the README promises you do not need is the one
    # thing being inside the repository costs.
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=. --alias:ithibati=../../../priv/static/ithibati.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  ithibati_invites: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
