defmodule Prizeflight.Prices.PriceUpdate do
  @moduledoc """
  Ecto schema + Cube.js model for ingested price events.

  The schema maps to the `price_events` Postgres table. The inline
  `PowerOfThree.cube/2` call emits a Cube.js YAML at compile time so
  the semantic layer is defined in the same place as the persistence
  schema — no handwritten YAML to drift.

  The cube's `count_distinct(event_id)` measure is what enforces
  idempotency on the read side. Duplicate inserts land in the fact
  table (append-only, no PK), and Cube collapses them when the
  rollup is queried. See `priv/repo/migrations/*create_price_events.exs`
  for the rationale.
  """

  use Ecto.Schema
  use PowerOfThree
  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime]

  schema "price_events" do
    field :event_id, Ecto.UUID
    field :route_id, :string
    field :origin_airport_code, :string
    field :destination_airport_code, :string
    field :departure_date, :utc_datetime
    field :price, :decimal
    field :currency, :string
    field :airline_code, :string
    field :recorded_at, :utc_datetime
    field :inserted_at, :utc_datetime
  end

  cube :price_events,
    description: "Flight price update events, append-only fact table" do
    # Dimensions — strings and time fields that slicers will group on.
    dimension(:route_id)
    dimension(:origin_airport_code)
    dimension(:destination_airport_code)
    dimension(:currency)
    dimension(:airline_code)
    dimension(:departure_date)
    dimension(:recorded_at)

    # Measures — `event_id_distinct` is the idempotency handle: duplicate
    # inserts at the fact table collapse to one event in the rollup
    # because retries share the same UUID.
    measure(:count)

    measure(:event_id,
      name: :event_id_distinct,
      type: :count_distinct,
      description: "Unique events — retries collapse by event_id"
    )

    measure(:price,
      name: :price_sum,
      type: :sum
    )

    measure(:price,
      name: :price_min,
      type: :min
    )

    measure(:price,
      name: :price_max,
      type: :max
    )
  end

  @required ~w(event_id route_id origin_airport_code destination_airport_code
               departure_date price currency recorded_at airline_code)a

  def changeset(price_update, params) do
    price_update
    |> cast(remap_timestamp(params), @required)
    |> validate_required(@required)
    |> validate_length(:origin_airport_code, is: 3)
    |> validate_length(:destination_airport_code, is: 3)
    |> validate_length(:currency, is: 3)
    |> validate_length(:airline_code, min: 2, max: 3)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> update_change(:origin_airport_code, &upcase/1)
    |> update_change(:destination_airport_code, &upcase/1)
    |> update_change(:currency, &upcase/1)
    |> update_change(:airline_code, &upcase/1)
  end

  # Inbound JSON uses "timestamp"; we store recorded_at to keep the field
  # name unambiguous against the audit timestamp set on insert.
  defp remap_timestamp(%{"timestamp" => ts} = params),
    do: params |> Map.put("recorded_at", ts) |> Map.delete("timestamp")

  defp remap_timestamp(%{timestamp: ts} = params),
    do: params |> Map.put(:recorded_at, ts) |> Map.delete(:timestamp)

  defp remap_timestamp(params), do: params

  defp upcase(nil), do: nil
  defp upcase(s) when is_binary(s), do: String.upcase(s)
end
