defmodule Prizeflight.Prices.PriceUpdateTest do
  use ExUnit.Case, async: true

  alias Prizeflight.Prices.PriceUpdate

  defp valid_params do
    %{
      "event_id" => "d0032287-9d1b-4767-a24b-20d21ede638f",
      "route_id" => "LAX-JFK-2025-10-26",
      "origin_airport_code" => "LAX",
      "destination_airport_code" => "JFK",
      "departure_date" => "2025-10-26T15:00:00Z",
      "price" => 350.75,
      "currency" => "USD",
      "timestamp" => "2025-07-07T15:00:00Z",
      "airline_code" => "AA"
    }
  end

  test "valid payload produces a valid changeset and remaps timestamp -> recorded_at" do
    cs = PriceUpdate.changeset(%PriceUpdate{}, valid_params())
    assert cs.valid?
    assert {:ok, %DateTime{}} = Map.fetch(cs.changes, :recorded_at)
    refute Map.has_key?(cs.changes, :timestamp)
  end

  test "missing required field fails" do
    cs = PriceUpdate.changeset(%PriceUpdate{}, Map.delete(valid_params(), "route_id"))
    refute cs.valid?
    assert %{route_id: ["can't be blank"]} = errors_on(cs)
  end

  test "negative price is rejected" do
    cs = PriceUpdate.changeset(%PriceUpdate{}, %{valid_params() | "price" => -1})
    refute cs.valid?
    assert %{price: _} = errors_on(cs)
  end

  test "airport code length is enforced" do
    cs = PriceUpdate.changeset(%PriceUpdate{}, %{valid_params() | "origin_airport_code" => "LA"})
    refute cs.valid?
    assert %{origin_airport_code: _} = errors_on(cs)
  end

  test "codes are uppercased" do
    params = %{valid_params() | "origin_airport_code" => "lax", "currency" => "usd"}
    cs = PriceUpdate.changeset(%PriceUpdate{}, params)
    assert cs.valid?
    assert cs.changes.origin_airport_code == "LAX"
    assert cs.changes.currency == "USD"
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, k ->
        opts |> Keyword.get(String.to_existing_atom(k), k) |> to_string()
      end)
    end)
  end
end
