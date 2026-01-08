defmodule LidlChef.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LidlChefWeb.Telemetry,
      LidlChef.Repo,
      {DNSCluster, query: Application.get_env(:lidl_chef, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LidlChef.PubSub},
      {Cachex, name: :recipe_search_cache},
      Arcana.TaskSupervisor,
      Arcana.Embedder.Local,
      Arcana.Graph.NERServing,
      LidlChefWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LidlChef.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LidlChefWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
