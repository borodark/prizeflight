# Prizeflight

> **Branch `postgres-cube-inline`** — Postgres ingest with a Cube.js
> semantic layer whose cube model is generated inline from the Ecto
> schema via [`power_of_3`](https://github.com/borodark/power_of_three).
> For the ClickHouse-backed iteration and the pivot story that led
> here, see `main` and [docs/INGEST_PIPELINE.md](docs/INGEST_PIPELINE.md).

Real-time flight price events arrive by HTTP, validate against an
Ecto changeset, and get pushed onto a lock-free per-scheduler ETS
shard. A timer-driven flusher pool drains each shard and batch-inserts
into an append-only Postgres fact table. Reads go through Cube.js —
which reads the same table and exposes pre-aggregated measures.

The cube model lives in the **same module as the Ecto schema**. One
`mix compile` emits the Cube YAML that the container picks up; edit
the schema, recompile, the model follows. No hand-maintained YAML
drift between the database columns and the semantic layer.

---

## The idea in one paragraph

Idempotency belongs on the read side. A PRIMARY KEY on `event_id`
is the obvious way to dedup at-least-once retries, but it puts a
uniqueness check on the write hot path for every row. In the DuckDB
iteration (see [docs/INGEST_PIPELINE.md](docs/INGEST_PIPELINE.md))
that constraint cost **200x throughput**. The fix then was to drop
the PK, accept duplicates in the fact table, and collapse them in
the rollup. This branch keeps that design: `price_events` has no
PK; the Cube measure `count_distinct(event_id)` collapses retries
at query time. Writers stay on the fast path; readers always see
deduped counts.

---

## Architecture

```
                  HTTP POST /api/price_updates
                             │
                             ▼
               PriceUpdateController.create/2
                             │
                             ▼
               Prices.validate_event/1  (Ecto.Changeset)
                             │
                             ▼
               Ingest.push/1     (:atomics.get + :ets.insert)
                             │    per-scheduler shard, lock-free
                             ▼
               Ingest.Flusher pool    (one GenServer per shard)
                             │    drains inactive ETS table on a timer
                             ▼
               Prices.insert_many/1   (chunked Repo.insert_all)
                             │
                             ▼
          ┌──────────────────────────────────────────┐
          │  Postgres                                │
          │  price_events — append-only, no PK       │
          └──────────────────────────────────────────┘
                             │
          reads              │
                             ▼
          ┌──────────────────────────────────────────┐
          │  Cube.js                                 │
          │  cube :price_events (generated YAML)     │
          │                                          │
          │  measures:                               │
          │    count                                 │
          │    event_id_distinct   ← dedup handle    │
          │    price_sum / price_min / price_max     │
          │                                          │
          │  dimensions:                             │
          │    route_id, origin_airport_code,        │
          │    destination_airport_code, currency,   │
          │    airline_code, departure_date (time),  │
          │    recorded_at (time)                    │
          └──────────────────────────────────────────┘
                             │
          ┌──────────┬───────┴─────────┬─────────────┐
          ▼          ▼                 ▼             ▼
      REST JSON    SQL via PG       GraphQL       Playground
      :4008        wire :15432      :4008         :4008/#/build
```

### Key modules

| Module | Role |
|---|---|
| `Prizeflight.Prices.PriceUpdate` | Ecto schema + changeset + inline `cube :price_events do … end` |
| `Prizeflight.Prices` | Batch writer — chunks to 5 000 rows to stay under Postgres's 65 535 bound-parameter cap |
| `Prizeflight.Repo` | Ecto Postgres repo (pool size 50 in dev) |
| `Prizeflight.Ingest` | Lock-free `push/1` — `:atomics.get` + `:ets.insert` |
| `Prizeflight.Ingest.BufferSupervisor` | Owns shard ETS tables + flusher pool |
| `Prizeflight.Ingest.Flusher` | One per shard; double-buffered ETS drain on a timer |
| `Prizeflight.Seed` | One-shot Task child that seeds 1M synthetic events on empty boot |
| `PrizeflightWeb.RootController` | `GET /` — JSON status + endpoint map + Cube pointer |
| `PrizeflightWeb.PriceUpdateController` | `POST /api/price_updates` |

### What compile generates

`mix compile` runs the `cube :price_events do … end` macro inside
`Prizeflight.Prices.PriceUpdate` and writes
`model/cubes/price_events.yaml`. The compose file bind-mounts
`./model` into the Cube.js container at `/cube/conf/model`, so the
cube the container reads is always whatever the latest compile
produced. The YAML is gitignored — it's a build artifact.

---

## Requirements

- Elixir 1.14+ / OTP 26+
- A container runtime for Postgres + Cube.js: `nerdctl` (tested),
  `docker`, or `podman`
- Free host ports: **17432** (Postgres), **4008** (Cube HTTP),
  **15432** (Cube PG wire), **4445** (Cube SQL), and one Phoenix
  port (**4003** recommended if 4000 is taken by another project)

Override DB connection via `PG_HOST`, `PG_PORT`, `PG_DB`, `PG_USER`,
`PG_PASSWORD`. Override the Phoenix port via `PORT`.

---

## Run the full stack

### 1. Bring up Postgres + Cube + Cubestore

```sh
cd ~/projects/prizeflight
nerdctl compose up -d
```

If a conflicting stack holds any of the above ports (e.g. the
`worraxe_*` containers from `learn_erl/power-of-three-examples`),
stop and remove them first:

```sh
nerdctl stop $(nerdctl ps --filter 'name=worraxe_' -q)
nerdctl rm   $(nerdctl ps -a --filter 'name=worraxe_' -q)
```

Verify Postgres and Cube are reachable:

```sh
PGPASSWORD=postgres psql -h localhost -p 17432 -U postgres -d prizeflight_dev -c '\dt'
curl -s http://localhost:4008/readyz
```

### 2. Set up the database

```sh
mix deps.get
mix ecto.setup        # create DB + run the price_events migration
```

### 3. Start Phoenix

```sh
PORT=4003 iex -S mix phx.server
```

On the first boot with an empty `price_events` table, the
`Prizeflight.Seed` Task child seeds **1,000,000** synthetic events
in the background (concurrency=16, ~14 seconds at ~75k ev/s). Log
line to watch for:

```
[seed] price_events is empty — seeding 1000000 events (concurrency=16)
[seed] done: 1000000 events in 13842 ms (72240 ev/s)
```

Disable with `config :prizeflight, :seed_on_empty, false` in
`config/dev.exs`, or override the count with `SEED_COUNT=100000`.

### 4. Check the service is alive

```sh
curl -s http://localhost:4003/ | jq
```

Returns a JSON summary including `status: "ok"`, the DB
coordinates, the ingest endpoint, and a ready-to-paste Cube REST
query template.

### 5. Open the Cube Playground

`http://localhost:4008/#/schema` — shows the `price_events` cube
with its dimensions and measures. `#/build` lets you drag measures
and dimensions into a query and see the result.

---

## Post events

### One-shot curl

```sh
curl -i -X POST http://localhost:4003/api/price_updates \
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

| Status | Meaning |
|---|---|
| `202 Accepted` | Validated and pushed to the ingest shard (flusher drains within `BUFFER_FLUSH_MS`, default 100 ms) |
| `422 Unprocessable Entity` | Validation failed — see `errors` body |
| `503 Service Unavailable` | Ingest buffer full — backpressure, retry later |

### Volume via benchmark

```sh
PORT=4003 PHX_SERVER=true BENCH_EVENTS=200000 BENCH_BATCH=20000 \
  mix run bench/run.exs
```

See [docs/benchmark_results.md](docs/benchmark_results.md) for the
four-scenario breakdown.

---

## Query Cube.js

Cube exposes three interfaces against the same cube model.

### REST / JSON

```sh
curl -s -X POST http://localhost:4008/cubejs-api/v1/load \
  -H 'content-type: application/json' \
  -H 'Authorization: dev-token' \
  -d '{
    "query": {
      "measures": [
        "price_events.count",
        "price_events.event_id_distinct",
        "price_events.price_min",
        "price_events.price_max",
        "price_events.price_sum"
      ],
      "dimensions": ["price_events.route_id"],
      "order": {"price_events.count": "desc"},
      "limit": 10
    }
  }' | jq '.data'
```

Inspect the generated Postgres SQL:

```sh
curl -s -X POST http://localhost:4008/cubejs-api/v1/sql \
  -H 'content-type: application/json' \
  -H 'Authorization: dev-token' \
  -d '{"query":{"measures":["price_events.event_id_distinct"]}}' | jq '.sql.sql'
```

### SQL via Postgres wire protocol

```sh
PGPASSWORD=any psql -h localhost -p 15432 -U cube -d db -c "
  SELECT route_id,
         measure(count)              AS events,
         measure(event_id_distinct)  AS unique_events,
         measure(price_min)          AS min_price,
         measure(price_max)          AS max_price
  FROM price_events
  GROUP BY 1
  ORDER BY events DESC
  LIMIT 10;
"
```

Any JDBC/ODBC BI tool that speaks Postgres wire works against
`:15432` as long as it calls `measure()` for cube measures.

### Raw Postgres (bypass Cube)

```sh
PGPASSWORD=postgres psql -h localhost -p 17432 -U postgres -d prizeflight_dev -c "
  SELECT count(*) AS raw_rows,
         count(DISTINCT event_id) AS unique_events
  FROM price_events;
"
```

The difference between `raw_rows` and `unique_events` is exactly the
number of duplicate inserts Cube silently collapses for you.

---

## Benchmarks

Current numbers on this branch (200,000 events, Postgres + Cube,
88 schedulers — see
[docs/benchmark_results.md](docs/benchmark_results.md) for the
full table, latency distribution, and comparison to the ClickHouse
iteration on `main`):

| Scenario | Throughput |
|---|---:|
| Writer direct (sequential) | 11.4k ev/s |
| Writer parallel (88×) | 75.3k ev/s |
| Ingest e2e (push → ETS → flusher → Postgres) | 48.9k ev/s |
| HTTP keep-alive (88 workers) | 3.9k ev/s (p50 24 ms) |

ClickHouse wins ~4–8× on the writer tier (columnar bulk vs. OLTP
prepared statements). HTTP is ~parity — bounded by request
latency, not the sink. Full picture in `docs/benchmark_results.md`.

### How to run the benchmark

**Prerequisites**

1. Compose stack up: `nerdctl compose up -d`
2. DB created and migrated: `mix ecto.setup` (once)
3. No Phoenix server already listening on the benchmark port (the
   bench spins up its own Endpoint when `PHX_SERVER=true`)

**Four scenarios the bench exercises**

| # | Scenario | What it measures | Hits HTTP? |
|---|---|---|---|
| 1 | Writer direct (sequential) | Single caller, `Prices.insert_many` in a loop | no |
| 2 | Writer parallel | N concurrent `insert_many` against the Ecto pool | no |
| 3 | Ingest e2e | `Ingest.push` → ETS shard → Flusher → Postgres | no |
| 4 | HTTP e2e (keep-alive) | `POST /api/price_updates` with N concurrent workers, persistent connections | yes |

Scenarios 1–3 always run. Scenario 4 runs only when `PHX_SERVER=true`.

**Full run (all four scenarios)**

```sh
PORT=4003 PHX_SERVER=true BENCH_EVENTS=500000 BENCH_BATCH=50000 \
  mix run bench/run.exs
```

**Writer-only run (skip HTTP, finishes faster)**

```sh
BENCH_EVENTS=500000 BENCH_BATCH=50000 mix run bench/run.exs
```

**Env var tunables**

| Var | Default | Meaning |
|---|---|---|
| `BENCH_EVENTS` | 1 000 000 | Total events per scenario |
| `BENCH_BATCH` | 50 000 | Rows per `insert_many` call (chunked to 5 000 internally) |
| `BENCH_CONCURRENCY` | `schedulers_online()` (88 on this host) | Parallel workers in scenarios 2 and 4 |
| `PHX_SERVER` | unset | Set to `true` to include scenario 4 |
| `PORT` | 4000 | Phoenix port the bench's HTTP client will target |
| `BUFFER_FLUSH_MS` | 100 | Flusher tick interval — lowers ingest-e2e latency |
| `BUFFER_POOL_SIZE` | 16 | Number of ETS shards / flusher GenServers |

The bench truncates `price_events` before each scenario so counts
are clean. Your seeded 1M rows will be gone after a run — set
`SEED_COUNT=0` to suppress the reseed on the next app start if you
don't want it back.

**Output to read**

Each scenario prints:

```
--- 2. Writer parallel — 88 concurrent insert_many, batch=50000 ---
  total time    : 1.521 s
  throughput    : 328707 events/s
  events in DB: 500000 across 200 (route, date) keys
```

HTTP scenario additionally prints a latency histogram:

```
  latency (μs)  : mean=22099 p50=23840 p95=27963 p99=31193 max=253280
  202 responses : 50000 / 50000
  non-202       : 0
```

`202 responses` should match `BENCH_EVENTS` exactly. A non-zero
`non-202` count points to buffer backpressure (503s) — lower
`BENCH_CONCURRENCY` or raise `BUFFER_POOL_SIZE`.

**Gotcha** — scenario 4 with `BENCH_EVENTS=500000` can overrun the
default `Task.async_stream` 120 s timeout. Either run HTTP with a
smaller `BENCH_EVENTS` (50 000–200 000) or raise the timeout in
`bench/run.exs:134`.

---

## Tests & static analysis

```sh
mix test                              # 9/9 pass
mix credo --strict                    # 0 issues
mix dialyzer                          # 0 errors (PLT cached)
mix compile --warnings-as-errors      # clean on our code
```

Warnings from the `power_of_3` dep (typing violations inside
`PowerOfThree.CubeFrame.from_query`) are not actionable on our side.

---

## Troubleshooting

**`eaddrinuse` on Phoenix start** — port 4000 is taken (often by
another BEAM service). Start with `PORT=4003 iex -S mix phx.server`.

**Cube Playground shows `orders_no_preagg` / `customers_cube`** —
you're hitting a cube_api from another project (the
`learn_erl/power-of-three-examples` `worraxe_cube_api` container).
Stop + remove those containers, then `nerdctl compose up -d` from
this project so the `prizeflight_cube_api` binds the ports.

**Seed didn't run** — check the log for `[seed]` lines. Common
causes: `:seed_on_empty` disabled in your env, table already had
rows, or Phoenix hadn't reconnected to a freshly-rebuilt Postgres
container. Trigger manually from IEx: `Prizeflight.Seed.run()`.

**No rows in Cube query despite events posted** — the flusher
drains every `BUFFER_FLUSH_MS` ms (default 100 ms). Wait 200 ms
after the last POST. If still empty, verify at the raw table:
`psql -p 17432 -d prizeflight_dev -c "SELECT count(*) FROM price_events"`.

**`Repo.insert_all` fails with "can not handle N parameters"** —
your batch size exceeded the Postgres 65 535 bound-parameter limit.
`Prices.insert_many/1` chunks to 5 000 rows internally, so callers
shouldn't hit this — the bench explicitly passes pre-chunked
batches. If you see it, re-check the call site.

---

## Layout

```
lib/prizeflight/
  ingest.ex                      — lock-free push/1
  ingest/buffer_supervisor.ex    — flusher pool supervisor
  ingest/flusher.ex              — per-shard drain GenServer
  prices.ex                      — chunked Repo.insert_all
  prices/price_update.ex         — Ecto schema + inline cube
  repo.ex                        — Ecto.Repo (Postgres)
  seed.ex                        — 1M-event startup seeder
  application.ex                 — supervision tree

lib/prizeflight_web/
  endpoint.ex, router.ex
  controllers/root_controller.ex         — GET /
  controllers/price_update_controller.ex — POST /api/price_updates
  controllers/fallback_controller.ex     — 422 / 503 mapping

bench/run.exs                    — 4-scenario benchmark
compose.yml                      — Postgres + Cube + Cubestore
priv/repo/migrations/            — price_events migration
model/cubes/price_events.yaml    — generated on compile (gitignored)

docs/DEMO.md                     — 5-minute end-to-end walkthrough
docs/INGEST_PIPELINE.md          — design: the 200x investigation
docs/benchmark_results.md        — ClickHouse + Postgres numbers

test/                            — 9 tests
```

---

## Further reading

- **[docs/DEMO.md](docs/DEMO.md)** — step-by-step demo
- **[docs/INGEST_PIPELINE.md](docs/INGEST_PIPELINE.md)** — the 200x
  `ON CONFLICT` investigation and why this table has no PK
- **[docs/benchmark_results.md](docs/benchmark_results.md)** —
  Postgres + ClickHouse numbers side-by-side
- **[`power_of_3`](https://github.com/borodark/power_of_three)** —
  the Ecto-to-Cube macro that keeps the cube model in lockstep with
  the schema

---

## License

Private — review copy only.
