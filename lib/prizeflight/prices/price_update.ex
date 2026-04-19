defmodule Prizeflight.Prices.PriceUpdate do
  @moduledoc """
  Validation-only schema for inbound price events. Persistence lives in
  `Prizeflight.DuckDB`; this struct is never inserted via Ecto.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:event_id, Ecto.UUID)
    field(:route_id, :string)
    field(:origin_airport_code, :string)
    field(:destination_airport_code, :string)
    field(:departure_date, :utc_datetime)
    field(:price, :decimal)
    field(:currency, :string)
    field(:recorded_at, :utc_datetime)
    field(:airline_code, :string)
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
