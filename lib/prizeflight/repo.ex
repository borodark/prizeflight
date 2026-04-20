defmodule Prizeflight.Repo do
  @moduledoc """
  Ecto repository for the Postgres ingest path. Writes land in
  `price_events`; reads aggregate via the Cube.js layer (see
  `Prizeflight.Prices.PriceUpdate` for the inline cube definition).
  """

  use Ecto.Repo,
    otp_app: :prizeflight,
    adapter: Ecto.Adapters.Postgres
end
