# Prizeflight

> **Branch `postgres-cube-inline`** — same ingest pipeline as `main`,
> different sink. Writes land in Postgres; reads go through a Cube.js
> semantic layer whose cube model is generated inline from the Ecto
> schema via [`power_of_3`](https://github.com/borodark/power_of_three).

High-throughput ingest for real-time flight price events. A Phoenix
endpoint accepts price updates, validates them against an Ecto
changeset, and pushes each row onto a lock-free per-scheduler ETS
shard. A flusher pool drains shards on a timer and batch-inserts
them into an append-only Postgres fact table. Cube.js reads the
table and exposes pre-aggregated measures; idempotency lives in the
cube's `count_distinct(event_id)` measure, not in a PRIMARY KEY on
the write path.

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
                            Prices.insert_many/1  (Repo.insert_all)
                                       │
                                       ▼
                     price_events (Postgres, append-only, no PK)
                                       │
                                       ▼              (reads)
                     Cube.js ◄─── `cube :price_events` ─── PriceUpdate
                     (measures: count, event_id_distinct,
                      price_sum / _min / _max; dimensions: route_id,
                      airports, currency, airline_code, departure_date,
                      recorded_at)
```

Key modules:

| Module | Role |
|---|---|
| `Prizeflight.Prices.PriceUpdate` | Ecto schema + validation changeset + inline `cube :price_events` |
| `Prizeflight.Prices` | Batch writer (`Repo.insert_all`) and changeset helpers |
| `Prizeflight.Repo` | Ecto Postgres repo |
| `Prizeflight.Ingest` | Lock-free `push/1` — `:ets.insert` into a scheduler-sharded table |
| `Prizeflight.Ingest.BufferSupervisor` | Owns the shard ETS tables and flusher pool |
| `Prizeflight.Ingest.Flusher` | Drains one shard on a timer, calls `Prices.insert_many/1` |
| `PrizeflightWeb.PriceUpdateController` | `POST /api/price_updates` |

The cube model YAML lands at `model/cubes/price_events.yaml` on
`mix compile` — bind-mounted into the Cube.js container at
`/cube/conf/model`. Edit the Ecto schema, recompile, Cube sees the
new model. One source of truth.

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
- Postgres reachable on `localhost:5432` (override via `PG_HOST`,
  `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASSWORD`). Dev defaults to
  `localhost:17432` to match the power-of-three compose stack.
- Cube.js + Cubestore containers for reads (optional for ingest-only
  development).

## Stack up (nerdctl / docker / podman compose)

```sh
nerdctl compose up -d
# Postgres at :17432, Cube HTTP at :4008, Cube PG wire at :15432
```

## Run

```sh
mix setup              # fetch deps, create DB, migrate
mix phx.server         # http://localhost:4000
```

`mix setup` creates the Postgres database and runs the migration
for the `price_events` table. The Cube.js cube model is generated
at `model/cubes/price_events.yaml` on every compile.

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

The numbers in [docs/benchmark_results.md](docs/benchmark_results.md)
are from the ClickHouse iteration on `main`. This branch swaps the
writer for `Repo.insert_all` into Postgres — those numbers need to
be regenerated against the compose stack. Expect the single-writer
ceiling to drop vs. ClickHouse (Postgres is OLTP, not columnar);
the Ingest e2e pipeline shape is unchanged.

To regenerate against this branch:

```sh
nerdctl compose up -d
PORT=4003 PHX_SERVER=true BENCH_EVENTS=500000 mix run bench/run.exs
```

See [docs/INGEST_PIPELINE.md](docs/INGEST_PIPELINE.md) for the
architectural backstory — the `ON CONFLICT` investigation from the
DuckDB pivot is still the reason this branch's Postgres table has
no PRIMARY KEY. Idempotency moved to the cube's
`count_distinct(event_id)` measure, same pattern as ClickHouse's
AggregatingMergeTree rollup.

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
