# The 200x Constraint

The benchmark printed 282 events per second and the room got quieter. DuckDB, an embedded analytical engine designed to chew through millions of rows in seconds, was inserting price events one at a time at the speed of a 1990s CSV import.

The pipeline had been running for ten minutes by then. A Phoenix endpoint accepting price update payloads, validating them against an Ecto changeset, pushing them onto a bounded GenStage producer, draining through a Broadway pipeline in batches of 500, landing in a single-writer DuckDB GenServer. End to end, it should have moved tens of thousands of events per second. It moved 282.

## The investigation

The pipeline had survived two architectural pivots before the benchmark even ran. The original brief was straightforward: a Phoenix endpoint that ingests real-time flight price events into a database, the kind of CRUD-shaped task that's been solved a thousand times. We started with the Postgres scaffold the project shipped with, then pivoted to ClickHouse — the workload is time-series data and `AggregatingMergeTree` is what time-series engines do. ClickHouse needed a server, so we downloaded the standalone binary. Then we pivoted again, to DuckDB. DuckDB embeds in the BEAM. No server, no port, no docker. The collapse-events-into-an-aggregating-merge-tree pattern doesn't translate cleanly — DuckDB has no engine-level "collapse on merge" — but a periodic GenServer running `INSERT ... GROUP BY ... ON CONFLICT DO UPDATE` covers the same ground. The whole thing fit in three files plus a rollup worker.

The numbers came in. 282 events per second.

The first hypothesis was the GenServer. DuckDB is single-writer; we'd routed every insert through one process to make that explicit. Maybe the mailbox was the bottleneck. It wasn't — a probe showed the mailbox was idle most of the time. The process was actively executing inserts, one at a time, and they were taking three milliseconds each.

The next hypothesis was the NIF. duckdbex runs on dirty schedulers, and dirty NIF dispatch has overhead. Maybe each `execute_statement` call was paying that overhead. A direct probe killed that theory too — prepared `INSERT` without the `ON CONFLICT` clause ran at 3,600 rows per second. Ten times faster, but still not what DuckDB should do.

The third probe was the one that mattered.

| Strategy | Throughput |
|---|---|
| Prepared `INSERT` in a transaction | 3,606 rows/s |
| Prepared `INSERT ... ON CONFLICT DO NOTHING` | **342 rows/s** |
| Single multi-VALUES `INSERT` | 26,004 rows/s |
| Appender API | 68,585 rows/s |

`ON CONFLICT` was costing 10x on top of an already-slow prepared insert. The PRIMARY KEY constraint check on the UUID — the obvious thing for idempotency — was the dominant cost on every single insert.

## The revelation

The constraint had felt free. We'd specified `event_id UUID PRIMARY KEY` because that's how you do idempotent ingest: the upstream producer guarantees `event_id` uniqueness, you make it the primary key, retries are silently skipped via `ON CONFLICT DO NOTHING`, and the math works out. It's the standard pattern. Postgres handles it without complaint.

DuckDB handles it too. It just handles it 200x slower than appending.

The reason isn't a bug — it's an architectural fit. DuckDB is a columnar OLAP engine. PRIMARY KEY constraints on a row-oriented insert path require row-by-row index lookups, the exact pattern columnar storage is designed to avoid. The Appender API exists because DuckDB's actual fast path is bulk column writes with no per-row checks. We'd asked the engine to do the thing it's slowest at, every time, for every event.

## The fix

The fix took three lines of SQL.

The PRIMARY KEY came off. The fact table became append-only. Duplicates can land in it, and they will, because at-least-once producers retry. The Appender API became the write path: open, add rows, close, ~70k rows per second.

Idempotency moved to the rollup. The `RollupWorker` now wraps its aggregation in a `WITH dedup AS (SELECT DISTINCT ON (event_id) * FROM price_updates ORDER BY event_id, inserted_at DESC)` CTE. Duplicates collapse before they're aggregated. The rollup table — which is what consumers actually query — sees each event exactly once.

The trade was implicit and worth naming: the fact table is no longer "correct" in isolation. It contains duplicates. Anything that queries it directly will count retries as new events. But the fact table isn't the read interface. The collapsed table is. By moving the constraint downstream, we moved it out of the hot path.

The DuckDB write rate went from 282 to 14,217 events per second. The pipeline as a whole — push to Broadway to DuckDB — landed at 13,471.

## The benchmark

Five scenarios, 100,000 events, 88 schedulers:

| Stage | Throughput | Notes |
|---|---|---|
| Producer raw push | 207k events/s | The ceiling |
| DuckDB direct (batch 500) | 14.2k events/s | The single-writer floor |
| Pipeline e2e | 13.4k events/s | 95% of floor — Broadway tax is small |
| HTTP keep-alive (88 workers) | 3.3k events/s | Bounded by 25ms per-request latency |
| Backpressure (buffer 200) | 200 ok / 8,600 overloaded | Parked callers timing out at 250ms — working as designed |

A batch-size sweep mapped the curve. Going from batch 100 to batch 500: 2.7x throughput. Going from 500 to 5000: 1.3x throughput, but 7x per-batch latency. The knee is at 500 — fast enough for most ingest, fresh enough for most consumers. The default sits there.

The HTTP keep-alive number is the one most likely to surprise. Switching from connect-per-request to persistent sockets gave us 2.5x throughput (1.3k → 3.3k events/s) at the same concurrency. The remaining ceiling isn't the network — it's the 25 millisecond per-request latency through Phoenix. With 88 concurrent workers each waiting 25ms per response, the math works out to ~3,500 requests per second, and that's exactly what we got. The next lever isn't more workers; it's a faster request path.

The Producer raw number — 207k events per second — is the most interesting figure on the table because it's not the bottleneck. It's headroom. The current pipeline delivers 13.4k events per second because DuckDB serializes through one writer GenServer. Beyond that ceiling, we'd shard by `route_id` across N DuckDB files, or swap the engine for one designed for parallel writes. But we don't need to. The Producer's parked-caller backpressure means we can absorb spikes without dropping events, the rollup means consumers see consistent data, and the BEAM has plenty of room above the current bottleneck.

## The lesson

Constraints have costs, and the cost depends on the engine. The same `ON CONFLICT DO NOTHING` clause that's free in Postgres is the dominant runtime cost in DuckDB, because the two engines were built to be fast at different things. The fix wasn't algorithmic — it was recognizing that the correctness property we wanted (idempotency at read time) didn't have to be enforced at the moment we wrote the rows. Moving it downstream was free.

The other lesson is that the benchmark is the architecture review. We wouldn't have caught this from code review. The structure looked right. The numbers said otherwise.
