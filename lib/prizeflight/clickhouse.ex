defmodule Prizeflight.Clickhouse do
  @moduledoc """
  ClickHouse backend. Canonical AggregatingMergeTree pattern:

    * `price_events` — raw events, `MergeTree`. The writer only ever
      touches this table. Source of truth; preserved for replay/audit.
    * `route_prices` — `AggregatingMergeTree` over `(route_id,
      departure_date)`, populated via materialized view.
    * `price_events_to_route_prices_mv` — fires on each INSERT into
      `price_events`, aggregates the inserted block by the AMT key, and
      writes the resulting partials into `route_prices`. Background
      merges then collapse partials with matching keys.

  Reads against `route_prices` use `GROUP BY` (not `FINAL`) so they see
  merged-plus-unmerged state cheaply.

  The writer path is lock-free on the app side — stateless `insert_many`
  hits the `:ch` pool directly, no GenServer serialization (see
  `Prizeflight.Ingest` for the push-side story).
  """

  use GenServer

  require Logger

  @pool_name :prizeflight_ch_pool

  # ---------- DDL ----------

  @ddl_raw """
  CREATE TABLE IF NOT EXISTS price_events (
    event_id            UUID,
    route_id            String,
    origin_airport_code      LowCardinality(String),
    destination_airport_code LowCardinality(String),
    departure_date      DateTime,
    price               Float64,
    currency            LowCardinality(String),
    recorded_at         DateTime,
    airline_code        LowCardinality(String),
    inserted_at         DateTime
  )
  ENGINE = MergeTree
  ORDER BY (route_id, departure_date, recorded_at, event_id)
  """

  @ddl_agg """
  CREATE TABLE IF NOT EXISTS route_prices (
    route_id            String,
    departure_date      DateTime,
    origin_airport_code LowCardinality(String),
    destination_airport_code LowCardinality(String),
    currency            LowCardinality(String),
    airline_code        LowCardinality(String),
    min_price           SimpleAggregateFunction(min, Float64),
    max_price           SimpleAggregateFunction(max, Float64),
    sample_count        SimpleAggregateFunction(sum, UInt64),
    last_price_at       SimpleAggregateFunction(max, Tuple(DateTime, Float64)),
    updated_at          SimpleAggregateFunction(max, DateTime)
  )
  ENGINE = AggregatingMergeTree
  ORDER BY (route_id, departure_date)
  """

  @ddl_mv """
  CREATE MATERIALIZED VIEW IF NOT EXISTS price_events_to_route_prices_mv
  TO route_prices AS
  SELECT
    route_id,
    departure_date,
    any(origin_airport_code)      AS origin_airport_code,
    any(destination_airport_code) AS destination_airport_code,
    any(currency)                 AS currency,
    any(airline_code)             AS airline_code,
    min(price)                    AS min_price,
    max(price)                    AS max_price,
    count()                       AS sample_count,
    max((recorded_at, price))     AS last_price_at,
    max(inserted_at)              AS updated_at
  FROM price_events
  GROUP BY route_id, departure_date
  """

  # ---------- Writer: raw events into price_events ----------

  @insert_sql "INSERT INTO price_events FORMAT RowBinary"

  @insert_types [
    "UUID",
    "String",
    "LowCardinality(String)",
    "LowCardinality(String)",
    "DateTime",
    "Float64",
    "LowCardinality(String)",
    "DateTime",
    "LowCardinality(String)",
    "DateTime"
  ]

  # ---------- Public API (stateless — bypass GenServer) ----------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Insert raw events into `price_events`. The materialized view
  auto-populates `route_prices`.
  """
  @spec insert_many([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert_many([]), do: {:ok, 0}

  def insert_many(rows) when is_list(rows) do
    encoded = Enum.map(rows, &encode_raw/1)
    n = length(encoded)

    case Ch.query(@pool_name, @insert_sql, encoded, types: @insert_types) do
      {:ok, _result} -> {:ok, n}
      {:error, e} -> {:error, e}
    end
  end

  @doc "Force a server-side merge — useful in tests before reading."
  @spec optimize(timeout()) :: :ok | {:error, term()}
  def optimize(_timeout \\ 60_000) do
    case Ch.query(@pool_name, "OPTIMIZE TABLE route_prices FINAL") do
      {:ok, _} -> :ok
      {:error, e} -> {:error, e}
    end
  end

  @doc "Run an arbitrary SQL statement. Returns `:ok`."
  @spec exec(binary(), timeout()) :: :ok | {:error, term()}
  def exec(sql, _timeout \\ 30_000) do
    case Ch.query(@pool_name, sql) do
      {:ok, _} -> :ok
      {:error, e} -> {:error, e}
    end
  end

  @doc "Fetch all rows for a SELECT."
  @spec fetch_all(binary(), timeout()) :: {:ok, [list()]} | {:error, term()}
  def fetch_all(sql, _timeout \\ 30_000) do
    case Ch.query(@pool_name, sql) do
      {:ok, %Ch.Result{rows: rows}} -> {:ok, rows}
      {:error, e} -> {:error, e}
    end
  end

  # ---------- Supervision shim ----------

  @impl true
  def init(opts) do
    cfg = Application.get_env(:prizeflight, __MODULE__, [])

    pool_opts = [
      name: @pool_name,
      scheme: opt(opts, cfg, :scheme, "http"),
      hostname: opt(opts, cfg, :hostname, "localhost"),
      port: opt(opts, cfg, :port, 8123),
      database: opt(opts, cfg, :database, "prizeflight"),
      username: opt(opts, cfg, :username, "prizeflight"),
      password: opt(opts, cfg, :password, "prizeflight"),
      pool_size: opt(opts, cfg, :pool_size, max(8, System.schedulers_online())),
      timeout: opt(opts, cfg, :timeout, :timer.seconds(60))
    ]

    {:ok, pool} = Ch.start_link(pool_opts)

    for ddl <- [@ddl_raw, @ddl_agg, @ddl_mv] do
      {:ok, _} = Ch.query(@pool_name, ddl)
    end

    {:ok, %{pool: pool}}
  end

  @impl true
  def terminate(_reason, %{pool: pool}) do
    if Process.alive?(pool), do: Process.exit(pool, :shutdown)
    :ok
  end

  # ---------- Encoding ----------

  # Column order matches @ddl_raw / @insert_types.
  defp encode_raw(row) do
    [
      Map.fetch!(row, :event_id),
      Map.fetch!(row, :route_id),
      Map.fetch!(row, :origin_airport_code),
      Map.fetch!(row, :destination_airport_code),
      Map.fetch!(row, :departure_date),
      to_float(Map.fetch!(row, :price)),
      Map.fetch!(row, :currency),
      Map.fetch!(row, :recorded_at),
      Map.fetch!(row, :airline_code),
      Map.fetch!(row, :inserted_at)
    ]
  end

  defp opt(opts, cfg, key, default) do
    Keyword.get(opts, key, Keyword.get(cfg, key, default))
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end
