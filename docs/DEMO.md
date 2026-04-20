# End-to-End Demo — Postgres + Cube.js Inline

Five minutes from a clean checkout of `postgres-cube-inline` to
querying a Cube.js cube over HTTP with real ingested flight price
data.

---

## 0. Prerequisites

- `nerdctl` (or `docker` / `podman`) compose
- Elixir 1.18+ / OTP 27+
- Free ports: **17432** (Postgres), **4008** (Cube HTTP), **15432**
  (Cube PG wire), **4445** (Cube SQL), **4003** (Phoenix)

If another stack owns any of those ports (e.g. the
power-of-three-examples `worraxe_*` containers map to 17432/4008/15432),
stop it first:

```sh
nerdctl stop $(nerdctl ps --filter 'name=worraxe_' -q)
```

---

## 1. Bring up the data stack

```sh
cd ~/projects/prizeflight
nerdctl compose up -d
```

What starts:

| Container | Port | Role |
|---|---|---|
| `prizeflight_postgresql` | 17432 | Postgres 18, append-only `price_events` table |
| `prizeflight_cube_api` | 4008 (HTTP), 15432 (PG wire), 4445 (SQL) | Cube.js semantic layer |
| `prizeflight_cubestore_router` / `_worker_1` | internal | Cube pre-aggregation store |

Verify Postgres:

```sh
PGPASSWORD=postgres psql -h localhost -p 17432 -U postgres -d prizeflight_dev -c '\dt'
```

Verify Cube (dev mode — any token works):

```sh
curl -s http://localhost:4008/readyz
```

---

## 2. Set up the database

```sh
mix deps.get
mix ecto.setup        # create DB + run the price_events migration
```

The migration creates `price_events` with no PRIMARY KEY — the cube's
`count_distinct(event_id)` measure handles idempotency at read time.

---

## 3. Start the Phoenix app

```sh
PORT=4003 iex -S mix phx.server
```

`PORT=4003` avoids the default 4000 if you have another service there.
`mix compile` (runs automatically) emits the cube YAML to
`model/cubes/price_events.yaml`, which Cube.js reads via the compose
bind-mount (`./model:/cube/conf/model`).

Verify the cube is visible:

```sh
curl -s http://localhost:4008/cubejs-api/v1/meta \
  -H 'Authorization: dev-token' | jq '.cubes[].name'
# => "price_events"
```

---

## 4. Ingest some data

### Option A: one-shot curl (smoke test)

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
# HTTP/1.1 202 Accepted
# {"status":"accepted","event_id":"d0032287-..."}
```

The flusher drains the ETS shard within 100 ms by default (see
`config/config.exs → BUFFER_FLUSH_MS`). The row is then in Postgres.

### Option B: volume via bench/run.exs

```sh
# Single 200k-event run exercising all four scenarios
PORT=4003 PHX_SERVER=true BENCH_EVENTS=200000 BENCH_BATCH=20000 \
  mix run bench/run.exs
```

Expect ~49k ev/s through the full Ingest e2e path, ~3.9k ev/s through
HTTP. See `docs/benchmark_results.md` for the full table.

---

## 5. Query Cube.js

Cube exposes three interfaces. Any of them reads the same cube model
(generated from the Ecto schema by `power_of_3`).

### 5a. REST API (JSON)

```sh
# Simple count
curl -s -X POST http://localhost:4008/cubejs-api/v1/load \
  -H 'content-type: application/json' \
  -H 'Authorization: dev-token' \
  -d '{
    "query": {
      "measures": [
        "price_events.count",
        "price_events.event_id_distinct"
      ]
    }
  }' | jq '.data'

# Per-route min/max/avg price, last 24h
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
      "timeDimensions": [{
        "dimension": "price_events.recorded_at",
        "dateRange": "last 24 hours"
      }],
      "order": {"price_events.count": "desc"},
      "limit": 10
    }
  }' | jq '.data'
```

Notice `count` (raw, includes any retries) vs. `event_id_distinct`
(dedup'd). If the ingest path sees a duplicate `event_id` twice
(at-least-once retry), `count` goes up by 2 but
`event_id_distinct` stays at 1. This is the read-side idempotency
lesson from `docs/INGEST_PIPELINE.md`.

### 5b. Cube SQL (Postgres wire protocol)

```sh
PGPASSWORD=any psql -h localhost -p 15432 -U cube -d db -c "
  SELECT route_id,
         measure(count) AS events,
         measure(event_id_distinct) AS unique_events,
         measure(price_min) AS min_price,
         measure(price_max) AS max_price
  FROM price_events
  GROUP BY 1
  ORDER BY events DESC
  LIMIT 10;
"
```

This is useful for BI tools, ad-hoc JOINs with other cubes, and
anyone already fluent in SQL. `measure()` is Cube's SQL extension —
plain `COUNT`/`SUM` would go against the raw table, bypassing
pre-aggregations.

### 5c. Check the raw fact table (no Cube)

```sh
PGPASSWORD=postgres psql -h localhost -p 17432 -U postgres -d prizeflight_dev -c "
  SELECT count(*), count(DISTINCT event_id) FROM price_events;
"
```

The gap between these two counts equals the number of duplicate
inserts that landed — and that Cube silently collapsed for you.

---

## 6. Inspect Cube's generated SQL

Cube will show you exactly what query it sent to Postgres:

```sh
curl -s -X POST http://localhost:4008/cubejs-api/v1/sql \
  -H 'content-type: application/json' \
  -H 'Authorization: dev-token' \
  -d '{
    "query": {
      "measures": ["price_events.event_id_distinct"],
      "dimensions": ["price_events.route_id"]
    }
  }' | jq '.sql.sql'
```

The cube's dimension/measure names map straight back to the Ecto
schema fields — one source of truth, and the generated SQL is readable.

---

## 7. Tear down

```sh
nerdctl compose down              # keep volumes
nerdctl compose down -v           # delete Postgres + Cubestore data
```

---

## Editing the cube

Change a field or add a measure in
`lib/prizeflight/prices/price_update.ex`. On the next `mix compile`,
`model/cubes/price_events.yaml` is rewritten. Cube.js picks up
changes automatically in dev mode. The Ecto schema and the Cube model
cannot drift — `power_of_3` generates the latter from the former.
