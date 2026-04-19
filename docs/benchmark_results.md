# Benchmark Results

Snapshot of the current ClickHouse-backed pipeline. See
[INGEST_PIPELINE.md](INGEST_PIPELINE.md) for the architectural
backstory (Postgres → DuckDB → ClickHouse pivots and the 200x
`ON CONFLICT` investigation).

## Environment

| | |
|---|---|
| Elixir / OTP | 1.18.3 / 27 |
| Schedulers | 88 |
| ClickHouse | 26.3.9.8 (container, localhost:8123) |
| Pool size | 88 (`:prizeflight_ch_pool`) |
| Batch size | 50 000 rows per `insert_many` |

## How to reproduce

```sh
# Start ClickHouse (nerdctl / docker / podman — any)
nerdctl start prizeflight_clickhouse   # or `docker run ...` from README

# Full run (all four scenarios, 500k events)
PORT=4003 PHX_SERVER=true BENCH_EVENTS=500000 mix run bench/run.exs

# HTTP scenario is sensitive to event count; for HTTP alone:
PORT=4003 PHX_SERVER=true BENCH_EVENTS=50000 mix run bench/run.exs
```

`PORT` overrides the dev endpoint's default 4000 so a co-resident
Phoenix app doesn't block startup. Tunables: `BENCH_EVENTS`,
`BENCH_BATCH`, `BENCH_CONCURRENCY`.

## Results

| Scenario | Events | Throughput | Wall time | Notes |
|---|---:|---:|---:|---|
| Writer direct (sequential `insert_many`) | 500 000 | **91 550 ev/s** | 5.46 s | Single caller, no contention — measures raw ClickHouse `:ch` pool writes. |
| Writer parallel (88 concurrent `insert_many`) | 500 000 | **328 707 ev/s** | 1.52 s | Pool saturates — 3.6x sequential. Headroom for further batch aggregation. |
| Ingest e2e (`push` → ETS shard → flusher → ClickHouse) | 500 000 | **206 645 ev/s** | 2.42 s | The full internal path. The ~37% gap vs. parallel writer is the flusher's timer-driven drain + batch assembly. |
| HTTP e2e (POST /api/price_updates, 88-way keep-alive) | 50 000 | **3 554 ev/s** | 14.07 s | Bounded by per-request latency (p50 24 ms, p95 30 ms), not the writer. |

### HTTP latency distribution (50 000 requests, 88-way keep-alive)

| Metric | μs | ms |
|---|---:|---:|
| mean | 23 397 | 23.4 |
| p50 | 24 076 | 24.1 |
| p95 | 29 741 | 29.7 |
| p99 | 32 551 | 32.6 |
| max | 245 681 | 245.7 |

All responses were `202 Accepted` (50 000 / 50 000 ok, 0 non-202,
0 dropped). No backpressure triggered at this rate.

## Reading the table

The three "inside-the-box" scenarios (1–3) all sit at six-figure
events-per-second. That's the **writer ceiling** — what the ingest
path can absorb when nothing HTTP is involved. The pipeline e2e
number (207k) is 63% of the parallel-writer peak, showing the ETS
shard + flusher adds about 37% overhead vs. the theoretical best.

HTTP (scenario 4) is a different world. At 3.5k events/s it's two
orders of magnitude slower than the ingest path itself. The math
holds up: 88 concurrent workers × (1 request / 24 ms) = ~3 700
req/s, which matches what we measured. The next lever isn't writer
tuning; it's trimming the Phoenix request path — JSON parsing,
changeset validation, and the 24 ms pipeline traversal.

## Comparison to DuckDB-era baseline

Historical numbers from [INGEST_PIPELINE.md](INGEST_PIPELINE.md) with
the DuckDB backend:

| Stage | DuckDB (old) | ClickHouse (current) | Speedup |
|---|---:|---:|---:|
| Writer direct | 14 200 ev/s | 91 550 ev/s | 6.4x |
| Pipeline e2e | 13 400 ev/s | 206 645 ev/s | 15.4x |
| HTTP keep-alive | 3 300 ev/s | 3 554 ev/s | ~same |

The writer-side wins track the engine swap (DuckDB's single-writer
GenServer vs. ClickHouse's stateless pool with MergeTree inserts).
HTTP is unchanged because it was already bottlenecked on request
latency, not the writer — confirming the "next lever is the request
path, not the engine" hypothesis from the pivot writeup.

## Known variances

- Scenario 4 with `BENCH_EVENTS=500000` overruns the default
  `Task.async_stream` timeout (120 s). Run HTTP with a smaller N or
  raise the timeout in `bench/run.exs:134`.
- `route_prices` row count assertions in the bench script expect the
  AggregatingMergeTree materialized view to have fired — occasionally
  the `wait_until_events` poll flakes under heavy sustained load.
  Re-run if you see a "timed out waiting" warning.
