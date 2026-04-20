defmodule PrizeflightWeb.ConnCase do
  @moduledoc """
  Conn-based test case. Starts `Prizeflight.Repo` once for the suite and
  checks out a Sandbox connection per test so writes don't leak between
  tests. The flusher pool is disabled in `config/test.exs` — the
  controller tests stop at the HTTP / ETS boundary.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @endpoint PrizeflightWeb.Endpoint

      use PrizeflightWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import PrizeflightWeb.ConnCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Prizeflight.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
