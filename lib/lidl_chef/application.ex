defmodule LidlChef.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    ReqLLM.put_key(:openai_api_key, "1234")

    children = [
      LidlChefWeb.Telemetry,
      LidlChef.Repo,
      {DNSCluster, query: Application.get_env(:lidl_chef, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LidlChef.PubSub},
      {Cachex, name: :recipe_search_cache},
      {Finch,
       name: LidlChef.Finch,
       pools: %{
         default: [
           conn_opts: [timeout: 6000_000],
           protocol: :http1,
           size: 10,
           count: 1,
           conn_max_idle_time: 3000_000
         ]
       }},
      Arcana.TaskSupervisor,
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
