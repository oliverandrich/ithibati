defmodule IthibatiEmail.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      IthibatiEmailWeb.Telemetry,
      IthibatiEmail.Repo,
      {DNSCluster, query: Application.get_env(:ithibati_email, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: IthibatiEmail.PubSub},
      # Start a worker by calling: IthibatiEmail.Worker.start_link(arg)
      # {IthibatiEmail.Worker, arg},
      # Start to serve requests, typically the last entry
      IthibatiEmailWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: IthibatiEmail.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IthibatiEmailWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
