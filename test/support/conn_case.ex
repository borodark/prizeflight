defmodule PrizeflightWeb.ConnCase do
  @moduledoc """
  Conn-based test case. No DB sandbox — DuckDB tests start their own
  isolated DB file via `Prizeflight.TestDuckDB`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint PrizeflightWeb.Endpoint

      use PrizeflightWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import PrizeflightWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
