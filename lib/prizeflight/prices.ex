defmodule Prizeflight.Prices do
  @moduledoc """
  Context for price update ingestion. Validation, row preparation, and
  the batch writer live here. Persistence is plain `Ecto.Repo.insert_all`
  against the append-only `price_events` fact table in Postgres —
  idempotency and aggregation are handled downstream by the Cube.js
  layer (see `Prizeflight.Prices.PriceUpdate` for the inline cube).
  """

  alias Prizeflight.Prices.PriceUpdate
  alias Prizeflight.Repo

  @spec validate_event(map()) :: {:ok, Ecto.Changeset.t()} | {:error, Ecto.Changeset.t()}
  def validate_event(params) when is_map(params) do
    changeset = PriceUpdate.changeset(%PriceUpdate{}, params)
    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  @spec changeset_to_row(Ecto.Changeset.t()) :: map()
  def changeset_to_row(%Ecto.Changeset{valid?: true, changes: changes}) do
    Map.put(changes, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  # Postgres wire-protocol caps a single prepared statement at 65 535
  # bound parameters. `price_events` has 10 columns, so any single
  # `insert_all` must stay under 6 553 rows. We pick 5 000 for headroom.
  @max_rows_per_insert 5_000

  @doc """
  Batch insert rows into `price_events`. No `on_conflict` — the table
  is append-only. Callers can pass any size; this function chunks
  internally to stay under the Postgres parameter limit. Returns
  `{:ok, total_inserted}` or `{:error, term}`.
  """
  @spec insert_many([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert_many([]), do: {:ok, 0}

  def insert_many(rows) when is_list(rows) do
    total =
      rows
      |> Enum.chunk_every(@max_rows_per_insert)
      |> Enum.reduce(0, fn chunk, acc ->
        {n, _} = Repo.insert_all(PriceUpdate, chunk)
        acc + n
      end)

    {:ok, total}
  rescue
    e -> {:error, e}
  end
end
