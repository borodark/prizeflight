defmodule PrizeflightWeb.PriceUpdateControllerTest do
  use PrizeflightWeb.ConnCase, async: false

  # The controller only delegates validation + push. End-to-end writes
  # are covered by `bench/run.exs` against a real Postgres + Cube stack;
  # here we just assert the HTTP contract.

  setup do
    stop_existing(Prizeflight.Ingest.BufferSupervisor)
    {:ok, sup} = Prizeflight.Ingest.BufferSupervisor.start_link()

    on_exit(fn ->
      try do
        if Process.alive?(sup), do: Supervisor.stop(sup, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp stop_existing(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp valid_payload do
    %{
      "event_id" => "d0032287-9d1b-4767-a24b-20d21ede638f",
      "route_id" => "LAX-JFK-2025-10-26",
      "origin_airport_code" => "LAX",
      "destination_airport_code" => "JFK",
      "departure_date" => "2025-10-26T15:00:00Z",
      "price" => 350.75,
      "currency" => "USD",
      "timestamp" => "2025-07-07T15:00:00Z",
      "airline_code" => "AA"
    }
  end

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "POST /api/price_updates with valid payload returns 202", %{conn: conn} do
    conn = json_post(conn, ~p"/api/price_updates", valid_payload())
    assert %{"status" => "accepted", "event_id" => id} = json_response(conn, 202)
    assert id == valid_payload()["event_id"]
  end

  test "POST /api/price_updates with invalid payload returns 422", %{conn: conn} do
    conn = json_post(conn, ~p"/api/price_updates", Map.delete(valid_payload(), "route_id"))
    assert %{"errors" => %{"route_id" => _}} = json_response(conn, 422)
  end
end
