defmodule Prizeflight.Prices do
  @moduledoc """
  Context for price update ingestion. Validation lives here; persistence
  goes through `Prizeflight.Clickhouse` (INSERT into `price_events`;
  CH's materialized view auto-populates `route_prices`).
  """

  alias Prizeflight.Clickhouse
  alias Prizeflight.Prices.PriceUpdate

  @spec validate_event(map()) :: {:ok, Ecto.Changeset.t()} | {:error, Ecto.Changeset.t()}
  def validate_event(params) when is_map(params) do
    changeset = PriceUpdate.changeset(%PriceUpdate{}, params)
    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  @spec changeset_to_row(Ecto.Changeset.t()) :: map()
  def changeset_to_row(%Ecto.Changeset{valid?: true, changes: changes}) do
    Map.put(changes, :inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @spec insert_many([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate insert_many(rows), to: Clickhouse
end
