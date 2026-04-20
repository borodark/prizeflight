defmodule PrizeflightWeb.RootController do
  @moduledoc """
  Landing page + healthcheck. Returns a JSON summary of the ingest
  service and a pointer to the Cube.js layer.
  """

  use PrizeflightWeb, :controller

  alias Ecto.Adapters.SQL

  def index(conn, _params) do
    case SQL.query(Prizeflight.Repo, "SELECT 1", []) do
      {:ok, _} -> render_summary(conn, :ok)
      {:error, _} -> render_summary(conn, :degraded)
    end
  end

  defp render_summary(conn, db_status) do
    cube_host = System.get_env("CUBE_HOST", "http://localhost:4008")

    body = %{
      service: "prizeflight",
      branch: "postgres-cube-inline",
      status: db_status,
      db: %{
        host: Application.get_env(:prizeflight, Prizeflight.Repo)[:hostname],
        port: Application.get_env(:prizeflight, Prizeflight.Repo)[:port],
        database: Application.get_env(:prizeflight, Prizeflight.Repo)[:database]
      },
      endpoints: %{
        ingest: %{
          method: "POST",
          path: "/api/price_updates",
          content_type: "application/json"
        }
      },
      cube: %{
        url: cube_host,
        rest: cube_host <> "/cubejs-api/v1/load",
        sql_pg_wire: "psql -h localhost -p 15432 -U cube -d db",
        example: %{
          method: "POST",
          url: cube_host <> "/cubejs-api/v1/load",
          headers: %{"Authorization" => "dev-token"},
          body: %{
            query: %{
              measures: [
                "price_events.count",
                "price_events.event_id_distinct"
              ]
            }
          }
        }
      },
      docs: [
        "README.md",
        "docs/DEMO.md",
        "docs/INGEST_PIPELINE.md",
        "docs/benchmark_results.md"
      ]
    }

    status = if db_status == :ok, do: 200, else: 503

    conn
    |> put_status(status)
    |> json(body)
  end
end
