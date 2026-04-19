defmodule PrizeflightWeb.Router do
  @moduledoc """
  HTTP routes. One public API pipeline; `POST /api/price_updates`
  is the sole ingest endpoint.
  """

  use PrizeflightWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", PrizeflightWeb do
    pipe_through(:api)

    post("/price_updates", PriceUpdateController, :create)
  end
end
