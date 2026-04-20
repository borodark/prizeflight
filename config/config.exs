# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

config :prizeflight,
  ecto_repos: [Prizeflight.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :prizeflight, Prizeflight.Repo,
  hostname: System.get_env("PG_HOST", "localhost"),
  port: String.to_integer(System.get_env("PG_PORT", "5432")),
  database: System.get_env("PG_DB", "prizeflight_dev"),
  username: System.get_env("PG_USER", "postgres"),
  password: System.get_env("PG_PASSWORD", "postgres"),
  pool_size: String.to_integer(System.get_env("PG_POOL_SIZE", "50"))

config :prizeflight, Prizeflight.Ingest.BufferSupervisor,
  pool_size: String.to_integer(System.get_env("BUFFER_POOL_SIZE", "16")),
  flush_ms: String.to_integer(System.get_env("BUFFER_FLUSH_MS", "100"))

# Configures the endpoint
config :prizeflight, PrizeflightWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: PrizeflightWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Prizeflight.PubSub,
  live_view: [signing_salt: "AJN3jhoG"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
