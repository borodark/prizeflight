defmodule Prizeflight.Application do
  @moduledoc """
  OTP application entry. Starts, in order:

    * `PrizeflightWeb.Telemetry` — VM + Phoenix metrics
    * `Prizeflight.Repo` — Ecto Postgres pool
    * `DNSCluster` — opt-in clustering
    * `Phoenix.PubSub` — cross-process messaging bus
    * `Prizeflight.Ingest.BufferSupervisor` — ETS shards + flusher pool
      (guarded by `:start_buffer_pool` so tests can opt out)
    * `PrizeflightWeb.Endpoint` — HTTP listener

  Restart strategy is `:one_for_one` — the pool, the repo, and the
  endpoint recover independently.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [PrizeflightWeb.Telemetry, Prizeflight.Repo] ++
        [
          {DNSCluster, query: Application.get_env(:prizeflight, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Prizeflight.PubSub}
        ] ++
        maybe(:start_buffer_pool, Prizeflight.Ingest.BufferSupervisor) ++
        [PrizeflightWeb.Endpoint] ++
        [
          %{
            id: :seed,
            start: {Task, :start_link, [&Prizeflight.Seed.maybe_seed/0]},
            restart: :temporary
          }
        ]

    opts = [strategy: :one_for_one, name: Prizeflight.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PrizeflightWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe(flag, child) do
    if Application.get_env(:prizeflight, flag, true), do: [child], else: []
  end
end
