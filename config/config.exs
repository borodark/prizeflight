# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

config :prizeflight,
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :prizeflight, Prizeflight.Clickhouse,
  hostname: System.get_env("CH_HOST", "localhost"),
  port: String.to_integer(System.get_env("CH_PORT", "8123")),
  database: System.get_env("CH_DB", "prizeflight"),
  username: System.get_env("CH_USER", "prizeflight"),
  password: System.get_env("CH_PASSWORD", "prizeflight")

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
