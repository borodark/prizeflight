defmodule PrizeflightWeb.PriceUpdateController do
  @moduledoc """
  HTTP entry point for price-update ingestion.

  `POST /api/price_updates` validates the JSON payload against
  `Prizeflight.Prices.validate_event/1` and, on success, pushes the
  row onto the lock-free `Prizeflight.Ingest` shard pool. Returns
  `202 Accepted` with the assigned `event_id`.

  Validation errors surface through `PrizeflightWeb.FallbackController`
  as `422 Unprocessable Entity`; a full ingest buffer returns
  `503 Service Unavailable`.
  """

  use PrizeflightWeb, :controller

  alias Prizeflight.{Ingest, Prices}

  action_fallback(PrizeflightWeb.FallbackController)

  def create(conn, params) do
    with {:ok, changeset} <- Prices.validate_event(params),
         row = Prices.changeset_to_row(changeset),
         :ok <- Ingest.push(row) do
      conn
      |> put_status(:accepted)
      |> json(%{status: "accepted", event_id: changeset.changes.event_id})
    end
  end
end
