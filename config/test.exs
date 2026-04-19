import Config

# Point tests at a dedicated CH database so the prod schema isn't touched.
config :prizeflight, Prizeflight.Clickhouse,
  database: "prizeflight_test",
  pool_size: 2

config :prizeflight, PrizeflightWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/erXYZGx1+Q9pFfsuQkBGyQ1NL3raZlu1mWjbqgKt5iKgwEm0V9vK6xh1IRqUXm3",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

# Tests don't need a live ClickHouse — the controller test stops at the
# HTTP layer (push lands in ETS, flushers log a warning if CH isn't up).
config :prizeflight, :start_clickhouse, false
config :prizeflight, :start_buffer_pool, false
