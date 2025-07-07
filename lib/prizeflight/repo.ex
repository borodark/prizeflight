defmodule Prizeflight.Repo do
  use Ecto.Repo,
    otp_app: :prizeflight,
    adapter: Ecto.Adapters.Postgres
end
