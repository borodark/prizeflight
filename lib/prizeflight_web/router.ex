defmodule PrizeflightWeb.Router do
  use PrizeflightWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", PrizeflightWeb do
    pipe_through(:api)

    post("/price_updates", PriceUpdateController, :create)
  end
end
