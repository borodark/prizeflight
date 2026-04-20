# Standalone benchmark script.
#
#   PHX_SERVER=true mix run bench/run.exs
#
# Scenarios:
#   1. Writer direct        — sequential `Prices.insert_many`
#   2. Writer parallel      — N concurrent `insert_many` against the Ch pool
#   3. Ingest e2e           — Ingest.push -> ETS shard -> flusher -> CH
#   4. HTTP e2e (keep-alive) — Bandit -> controller -> Ingest -> ...
#
# Tunables: BENCH_EVENTS, BENCH_BATCH, BENCH_CONCURRENCY.
# Also honors BUFFER_POOL_SIZE, BUFFER_FLUSH_MS (see config/config.exs).

require Logger

defmodule Bench do
  @events String.to_integer(System.get_env("BENCH_EVENTS", "1000000"))
  @batch String.to_integer(System.get_env("BENCH_BATCH", "50000"))
  @concurrency String.to_integer(
                 System.get_env(
                   "BENCH_CONCURRENCY",
                   to_string(System.schedulers_online())
                 )
               )

  alias Prizeflight.{Ingest, Prices, Repo}

  def run do
    Logger.configure(level: :warning)

    IO.puts("\n=== prizeflight bench ===")
    IO.puts("events=#{@events}  batch=#{@batch}  concurrency=#{@concurrency}")
    IO.puts("schedulers=#{System.schedulers_online()}  HTTP server: #{server_running?()}")

    bench_writer_direct()
    bench_writer_parallel()
    bench_ingest_e2e()

    if server_running?() do
      bench_http_e2e()
    else
      IO.puts("\n--- 4. HTTP e2e — SKIPPED (set PHX_SERVER=true) ---")
    end
  end

  # ---------- 1. Writer direct (sequential) ----------

  defp bench_writer_direct do
    section("1. Writer direct — sequential insert_many, batch=#{@batch}")
    truncate!()
    rows = build_rows(@events)
    batches = Enum.chunk_every(rows, @batch)

    {us, _} =
      :timer.tc(fn ->
        Enum.each(batches, fn b -> {:ok, _} = Prices.insert_many(b) end)
      end)

    report(us)
    print_count()
  end

  # ---------- 2. Writer parallel ----------

  defp bench_writer_parallel do
    section("2. Writer parallel — #{@concurrency} concurrent insert_many, batch=#{@batch}")
    truncate!()
    rows = build_rows(@events)
    batches = Enum.chunk_every(rows, @batch)

    {us, _} =
      :timer.tc(fn ->
        Task.async_stream(
          batches,
          fn b -> {:ok, _} = Prices.insert_many(b) end,
          max_concurrency: @concurrency,
          timeout: 60_000,
          ordered: false
        )
        |> Stream.run()
      end)

    report(us)
    print_count()
  end

  # ---------- 3. Ingest e2e (no HTTP) ----------

  defp bench_ingest_e2e do
    section("3. Ingest e2e — push -> ETS shard -> flusher -> CH (#{@concurrency}-way push)")
    truncate!()
    rows = build_rows(@events)
    per_worker = ceil_div(@events, @concurrency)
    chunks = Enum.chunk_every(rows, per_worker)

    {us, _} =
      :timer.tc(fn ->
        Task.async_stream(
          chunks,
          fn chunk -> Enum.each(chunk, &Ingest.push/1) end,
          max_concurrency: @concurrency,
          timeout: 120_000,
          ordered: false
        )
        |> Stream.run()

        :ok = Ingest.flush_all()
        wait_until_events(@events, 120_000)
      end)

    report(us)
    print_count()
  end

  # ---------- 4. HTTP e2e ----------

  defp bench_http_e2e do
    section("4. HTTP e2e — POST /api/price_updates, #{@concurrency}-way keep-alive")
    truncate!()
    port = http_port()
    per_worker = ceil_div(@events, @concurrency)
    chunks = build_payloads(@events) |> Enum.chunk_every(per_worker)

    {us, results} =
      :timer.tc(fn ->
        results =
          Task.async_stream(
            chunks,
            fn chunk -> run_keepalive_worker(port, chunk) end,
            max_concurrency: @concurrency,
            timeout: 120_000,
            ordered: false
          )
          |> Enum.flat_map(fn {:ok, list} -> list end)

        :ok = Ingest.flush_all()
        wait_until_events(@events, 120_000)
        results
      end)

    {oks, others} = Enum.split_with(results, fn {status, _} -> status == 202 end)
    lat_us = oks |> Enum.map(fn {_, us} -> us end) |> Enum.sort()

    report(us)
    IO.puts("  202 responses : #{length(oks)} / #{length(results)}")
    IO.puts("  non-202       : #{length(others)}")
    print_latencies(lat_us)
    print_count()
  end

  # ---------- HTTP helpers ----------

  defp server_running? do
    case PrizeflightWeb.Endpoint.server_info(:http) do
      {:ok, {_, _}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp http_port do
    {:ok, {_, port}} = PrizeflightWeb.Endpoint.server_info(:http)
    port
  end

  defp run_keepalive_worker(port, payloads) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port,
        [:binary, packet: :raw, active: false, nodelay: true],
        10_000
      )

    results = Enum.map(payloads, fn p -> http_post(sock, p) end)
    :gen_tcp.close(sock)
    results
  end

  defp http_post(sock, json) do
    body = Jason.encode!(json)

    req = [
      "POST /api/price_updates HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      "Connection: keep-alive\r\n\r\n",
      body
    ]

    t0 = System.monotonic_time(:microsecond)
    :ok = :gen_tcp.send(sock, req)
    {status, content_length} = read_response_head(sock)
    :ok = drain_body(sock, content_length)
    {status, System.monotonic_time(:microsecond) - t0}
  end

  defp read_response_head(sock) do
    :ok = :inet.setopts(sock, packet: :http_bin)
    {:ok, {:http_response, _ver, status, _}} = :gen_tcp.recv(sock, 0, 30_000)
    cl = read_headers(sock, 0)
    :ok = :inet.setopts(sock, packet: :raw)
    {status, cl}
  end

  defp read_headers(sock, content_length) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, :http_eoh} ->
        content_length

      {:ok, {:http_header, _, :"Content-Length", _, val}} ->
        read_headers(sock, String.to_integer(to_string(val)))

      {:ok, {:http_header, _, _, _, _}} ->
        read_headers(sock, content_length)
    end
  end

  defp drain_body(_sock, 0), do: :ok

  defp drain_body(sock, n) do
    {:ok, _} = :gen_tcp.recv(sock, n, 30_000)
    :ok
  end

  # ---------- Data + DB helpers ----------

  defp truncate! do
    Repo.query!("TRUNCATE TABLE price_events")
    :ok
  end

  defp build_rows(n) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    base_dep = ~U[2025-10-26 15:00:00Z]

    Enum.map(1..n, fn i ->
      %{
        event_id: Ecto.UUID.generate(),
        route_id: "RT-#{rem(i, 200)}",
        origin_airport_code: "LAX",
        destination_airport_code: "JFK",
        departure_date: base_dep,
        price: 100.0 + :rand.uniform() * 500,
        currency: "USD",
        recorded_at: DateTime.add(now, -:rand.uniform(86_400), :second),
        airline_code: "AA",
        inserted_at: now
      }
    end)
  end

  defp build_payloads(n) do
    Enum.map(1..n, fn i ->
      %{
        "event_id" => Ecto.UUID.generate(),
        "route_id" => "RT-#{rem(i, 200)}",
        "origin_airport_code" => "LAX",
        "destination_airport_code" => "JFK",
        "departure_date" => "2025-10-26T15:00:00Z",
        "price" => 100.0 + :rand.uniform() * 500,
        "currency" => "USD",
        "timestamp" => "2025-07-07T15:00:00Z",
        "airline_code" => "AA"
      }
    end)
  end

  defp wait_until_events(target, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_events(target, deadline)
  end

  defp do_wait_events(target, deadline) do
    n = events_in_db()

    cond do
      n >= target ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        IO.puts("  WARN: timed out waiting for events, got #{n}/#{target}")
        :timeout

      true ->
        Process.sleep(20)
        do_wait_events(target, deadline)
    end
  end

  defp events_in_db do
    # Count distinct events — mirrors the cube's count_distinct(event_id)
    # measure so duplicate retries don't inflate the total.
    %{rows: [[n]]} =
      Repo.query!("SELECT count(DISTINCT event_id)::bigint FROM price_events")

    n
  end

  defp print_count do
    %{rows: [[keys]]} =
      Repo.query!(
        "SELECT count(*)::bigint FROM (" <>
          "SELECT 1 FROM price_events GROUP BY route_id, departure_date) sub"
      )

    IO.puts("  events in DB: #{events_in_db()} across #{keys} (route, date) keys")
  end

  defp section(title), do: IO.puts("\n--- #{title} ---")

  defp report(us) do
    secs = us / 1_000_000
    IO.puts("  total time    : #{Float.round(secs, 3)} s")
    IO.puts("  throughput    : #{round(@events / secs)} events/s")
  end

  defp print_latencies([]), do: IO.puts("  (no successful samples)")

  defp print_latencies(us_sorted) do
    n = length(us_sorted)
    p = fn pct -> Enum.at(us_sorted, min(n - 1, trunc(n * pct))) end
    mean = Enum.sum(us_sorted) / n

    IO.puts(
      "  latency (μs)  : mean=#{round(mean)} p50=#{p.(0.50)} " <>
        "p95=#{p.(0.95)} p99=#{p.(0.99)} max=#{Enum.max(us_sorted)}"
    )
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end

Bench.run()
