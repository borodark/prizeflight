defmodule Prizeflight do
  @moduledoc """
  Top-level namespace for the Prizeflight ingest service.

  Prizeflight accepts real-time flight price events over HTTP, lands
  them in an append-only Postgres fact table via a lock-free
  per-scheduler ETS shard + flusher pool, and exposes rollups through
  a Cube.js semantic layer whose model is generated inline from the
  Ecto schema.

  The hot path (push → ETS → flusher → Postgres) is lock-free on the
  app side: writers only touch `:atomics` + `:ets.insert`, no
  GenServer serialization. See `Prizeflight.Ingest` for the push
  side, `Prizeflight.Prices` for the batch writer, and
  `Prizeflight.Prices.PriceUpdate` for the schema + inline cube
  definition.

  Design tradeoffs, including the Postgres → DuckDB → ClickHouse
  pivot history and the `ON CONFLICT` investigation that led to the
  current append-only design, are documented in
  `docs/INGEST_PIPELINE.md`.
  """
end
