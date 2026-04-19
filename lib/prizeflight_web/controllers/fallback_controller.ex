defmodule PrizeflightWeb.FallbackController do
  use PrizeflightWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: PrizeflightWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :overloaded}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{detail: "ingest buffer full, retry later"}})
  end
end
