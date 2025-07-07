defmodule Prizeflight.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PrizeflightWeb.Telemetry,
      Prizeflight.Repo,
      {DNSCluster, query: Application.get_env(:prizeflight, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Prizeflight.PubSub},
      # Start a worker by calling: Prizeflight.Worker.start_link(arg)
      # {Prizeflight.Worker, arg},
      # Start to serve requests, typically the last entry
      PrizeflightWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Prizeflight.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PrizeflightWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
