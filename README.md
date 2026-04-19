# Prizeflight

High-throughput ingest for real-time flight price events. A Phoenix
endpoint accepts price updates, validates them against an Ecto
changeset, and pushes each row onto a lock-free per-scheduler ETS
shard. A flusher pool drains shards on a timer and writes batches
directly into ClickHouse, where a `MergeTree` fact table plus an
`AggregatingMergeTree` materialized view maintain per-route rollups
with no GenServer serialization on the hot path.

## Architecture at a glance

```
HTTP POST ─► PriceUpdateController ─► Prices.validate_event
                                       │
                                       ▼
                            Ingest.push/1  (:atomics + :ets.insert)
                                       │   per-scheduler shard
                                       ▼
                            Ingest.Flusher pool  (one GenServer per shard)
                                       │   timer-driven drain of inactive table
                                       ▼
                            Prizeflight.Clickhouse.insert_many/2
                                       │   stateless, hits :ch pool
                                       ▼
                     price_events (MergeTree)  ─MV─►  route_prices (AggregatingMergeTree)
```

Key modules:

| Module | Role |
|---|---|
| `Prizeflight.Prices.PriceUpdate` | Ecto schema + validation changeset |
| `Prizeflight.Ingest` | Lock-free `push/1` — `:ets.insert` into a scheduler-sharded table |
| `Prizeflight.Ingest.BufferSupervisor` | Owns the shard ETS tables and flusher pool |
| `Prizeflight.Ingest.Flusher` | Drains one shard on a timer, calls the configured writer |
| `Prizeflight.Clickhouse` | DDL bootstrap + stateless `insert_many` via a `:ch` pool |
| `PrizeflightWeb.PriceUpdateController` | `POST /api/price_updates` |

## Design tradeoffs

The pipeline survived two engine pivots (Postgres → DuckDB → ClickHouse)
and the benchmark caught a 200x regression caused by a seemingly free
constraint. The writeup in **[docs/INGEST_PIPELINE.md](docs/INGEST_PIPELINE.md)**
walks through the investigation — why `ON CONFLICT DO NOTHING` costs
200x on a columnar engine, and how moving idempotency from the write
path to the rollup recovered the throughput. Read that before
reviewing the code.

## Requirements

- Elixir 1.14+ / OTP 26+
- ClickHouse server reachable on `localhost:8123` (HTTP) with
  database `prizeflight` and user `prizeflight`/`prizeflight`.
  Override via `CH_HOST`, `CH_PORT`, `CH_DB`, `CH_USER`,
  `CH_PASSWORD`.

Quick ClickHouse (one-shot, local):

```sh
docker run -d --name ch -p 8123:8123 -p 9000:9000 \
  -e CLICKHOUSE_DB=prizeflight \
  -e CLICKHOUSE_USER=prizeflight \
  -e CLICKHOUSE_PASSWORD=prizeflight \
  clickhouse/clickhouse-server:latest
```

## Run

```sh
mix setup              # fetch deps
mix phx.server         # http://localhost:4000
```

DDL is applied on startup by `Prizeflight.Clickhouse` — no separate
migration step.

## Post an event

```sh
curl -i -X POST http://localhost:4000/api/price_updates \
  -H 'content-type: application/json' \
  -d '{
    "event_id": "d0032287-9d1b-4767-a24b-20d21ede638f",
    "route_id": "LAX-JFK-2025-10-26",
    "origin_airport_code": "LAX",
    "destination_airport_code": "JFK",
    "departure_date": "2025-10-26T15:00:00Z",
    "price": 350.75,
    "currency": "USD",
    "timestamp": "2025-07-07T15:00:00Z",
    "airline_code": "AA"
  }'
```

Responses:

| Status | Meaning |
|---|---|
| `202 Accepted` | Validated and pushed to the ingest shard |
| `422 Unprocessable Entity` | Validation failed — see `errors` body |
| `503 Service Unavailable` | Ingest buffer full; retry later |

## Tests & static analysis

```sh
mix test                   # 9 tests, 0 failures
mix dialyzer               # 0 errors (PLT cached in _build/)
mix compile --warnings-as-errors
```

## Benchmarks

```sh
PHX_SERVER=true mix run bench/run.exs
```

Tunables: `BENCH_EVENTS` (default 1,000,000), `BENCH_BATCH`
(default 50,000), `BENCH_CONCURRENCY` (default
`System.schedulers_online()`). Set `PHX_SERVER=true` to include the
HTTP keep-alive scenario.

Headline numbers from the current ClickHouse pipeline (88
schedulers, 500 000 events, batch 50 000) — see
**[docs/benchmark_results.md](docs/benchmark_results.md)** for the
full table including latency distribution and comparison to the
DuckDB-era baseline:

| Scenario | Throughput |
|---|---:|
| Writer direct (sequential) | 91.5k ev/s |
| Writer parallel (88×) | 328.7k ev/s |
| Ingest e2e (push → ETS → flusher → ClickHouse) | 206.6k ev/s |
| HTTP keep-alive (88 workers) | 3.5k ev/s |

See [docs/INGEST_PIPELINE.md](docs/INGEST_PIPELINE.md) for the
architectural backstory and the 200x `ON CONFLICT` investigation
that moved the pipeline off DuckDB.

## Layout

```
lib/prizeflight/             — ingest + clickhouse + schema
lib/prizeflight_web/         — Phoenix endpoint, router, controllers
bench/run.exs                — standalone benchmark
docs/INGEST_PIPELINE.md      — design writeup: the 200x investigation
docs/benchmark_results.md    — current numbers + reproduction steps
test/                        — unit + integration (9 tests)
```

## License

Private — review copy only.
