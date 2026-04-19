defmodule PrizeflightWeb.PriceUpdateController do
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
