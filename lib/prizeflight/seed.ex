defmodule Prizeflight.Seed do
  @moduledoc """
  One-shot startup seeder. When the `price_events` table is empty and
  `:seed_on_empty` is set in config, generates and inserts
  `:seed_count` synthetic events so the Cube.js Playground has
  something to chart on a fresh DB.

  Runs async off a `Task` child — app startup is never blocked. Logs
  start and completion at `:info`. On non-empty tables, logs the
  existing row count and returns immediately.

  Writes go directly through `Prices.insert_many/1` (which chunks to
  5 000 rows internally for the Postgres bound-parameter limit),
  parallelized across `Task.async_stream` to saturate the dev pool.
  """

  require Logger

  alias Prizeflight.{Prices, Repo}

  @default_count 1_000_000
  @chunk_size 5_000
  @default_concurrency 16

  @doc """
  Called from `Prizeflight.Application` as `{Task, &Seed.maybe_seed/0}`.
  Returns immediately; the actual work runs in a detached task so the
  supervision tree doesn't wait.
  """
  def maybe_seed do
    if Application.get_env(:prizeflight, :seed_on_empty, false) do
      Task.start(__MODULE__, :run, [])
    end

    :ok
  end

  @doc "Seed now — idempotent, skips when table is non-empty."
  def run do
    count = Application.get_env(:prizeflight, :seed_count, @default_count)
    concurrency = Application.get_env(:prizeflight, :seed_concurrency, @default_concurrency)

    case Repo.query!("SELECT count(*)::bigint FROM price_events") do
      %{rows: [[0]]} ->
        Logger.info("[seed] price_events is empty — seeding #{count} events (concurrency=#{concurrency})")
        t0 = System.monotonic_time(:millisecond)
        insert_all(count, concurrency)
        took = System.monotonic_time(:millisecond) - t0
        rate = round(count * 1_000 / took)
        Logger.info("[seed] done: #{count} events in #{took} ms (#{rate} ev/s)")

      %{rows: [[n]]} ->
        Logger.info("[seed] price_events has #{n} rows — skipping")
    end
  end

  defp insert_all(total, concurrency) do
    chunks = ceil_div(total, @chunk_size)

    1..chunks
    |> Task.async_stream(
      fn chunk_idx ->
        n = if chunk_idx == chunks, do: total - (chunks - 1) * @chunk_size, else: @chunk_size
        rows = build_rows(n, (chunk_idx - 1) * @chunk_size)
        {:ok, _} = Prices.insert_many(rows)
      end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: 60_000
    )
    |> Stream.run()
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  @airports ~w(LAX JFK ORD ATL DFW SFO SEA MIA BOS IAH)
  @airlines ~w(AA UA DL WN B6 AS NK F9)
  @base_dep ~U[2025-10-26 15:00:00Z]

  defp build_rows(n, offset) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    n_airports = length(@airports)
    n_airlines = length(@airlines)

    Enum.map(1..n, fn i ->
      idx = i + offset
      origin = Enum.at(@airports, rem(idx, n_airports))
      dest = Enum.at(@airports, rem(idx + 3, n_airports))

      %{
        event_id: Ecto.UUID.bingenerate() |> Ecto.UUID.load() |> elem(1),
        route_id: "#{origin}-#{dest}-#{rem(idx, 30)}",
        origin_airport_code: origin,
        destination_airport_code: dest,
        departure_date: DateTime.add(@base_dep, rem(idx, 30) * 86_400, :second),
        price: Decimal.new("#{100 + :rand.uniform(500)}.#{:rand.uniform(99)}"),
        currency: "USD",
        recorded_at: DateTime.add(now, -:rand.uniform(86_400 * 7), :second),
        airline_code: Enum.at(@airlines, rem(idx, n_airlines)),
        inserted_at: now
      }
    end)
  end
end
