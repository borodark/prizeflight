import Config

# Point tests at a dedicated Postgres database with Sandbox isolation so
# tests can run in parallel without data bleed.
config :prizeflight, Prizeflight.Repo,
  port: String.to_integer(System.get_env("PG_PORT") || "17432"),
  database: "prizeflight_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :prizeflight, PrizeflightWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/erXYZGx1+Q9pFfsuQkBGyQ1NL3raZlu1mWjbqgKt5iKgwEm0V9vK6xh1IRqUXm3",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

# Tests exercise the HTTP → Ingest → ETS boundary. The flusher pool is
# disabled so buffered rows don't try to hit Postgres without the Sandbox
# checkout, and the Repo is started directly by the test helper instead
# of the supervision tree to keep it Sandbox-clean.
config :prizeflight, :start_buffer_pool, false
config :prizeflight, :seed_on_empty, false
