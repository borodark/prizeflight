defmodule Prizeflight.Repo.Migrations.CreatePriceEvents do
  use Ecto.Migration

  @doc """
  Append-only fact table for ingested price events.

  No PRIMARY KEY on `event_id` — the ingest path stays on the fastest
  Postgres write path (no per-row uniqueness check). Idempotency moves
  downstream: the Cube.js layer uses `count_distinct(event_id)` to
  collapse retries at read time. This is the same pattern the
  ClickHouse iteration used with its AggregatingMergeTree, and the
  lesson from the DuckDB pivot documented in docs/INGEST_PIPELINE.md.
  """
  def change do
    create table(:price_events, primary_key: false) do
      add :event_id, :uuid, null: false
      add :route_id, :string, null: false
      add :origin_airport_code, :string, size: 3, null: false
      add :destination_airport_code, :string, size: 3, null: false
      add :departure_date, :utc_datetime, null: false
      add :price, :decimal, precision: 12, scale: 4, null: false
      add :currency, :string, size: 3, null: false
      add :airline_code, :string, size: 3, null: false
      add :recorded_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    # Read path: Cube pre-aggregations key on (route_id, departure_date).
    # Index supports both Cube's own queries and ad-hoc rollups.
    create index(:price_events, [:route_id, :departure_date])
    create index(:price_events, [:recorded_at])
  end
end
