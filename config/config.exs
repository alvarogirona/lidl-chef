# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :lidl_chef, LidlChef.Repo,
  types: LidlChef.PostgrexTypes,
  log: false

config :lidl_chef,
  ecto_repos: [LidlChef.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :lidl_chef, LidlChefWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LidlChefWeb.ErrorHTML, json: LidlChefWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LidlChef.PubSub,
  live_view: [signing_salt: "HbAjP0QO"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :lidl_chef, LidlChef.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  lidl_chef: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  lidl_chef: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :lidl_chef, :finch_pools,
  default: [
    conn_opts: [timeout: 6000_000],
    protocol: :http1,
    size: 10,
    count: 1,
    conn_max_idle_time: 3000_000
  ]

# Configure Nx backend for EXLA (AMD hardware)
config :nx,
  default_backend: EXLA.Backend,
  default_defn_options: [compiler: EXLA]

# Configure EXLA for ROCm (AMD) - falls back to CPU if not available
config :exla,
  clients: [
    host: [platform: :host]
  ],
  default_client: :host

# Configure Arcana RAG system
config :arcana,
  repo: LidlChef.Repo,
  embedder: LidlChef.Embedder,
  chunker: :default,
  llm: &LidlChef.LLM.complete/1,
  graph: [
    enabled: true,
    community_levels: 5,
    resolution: 1.0,
    extractor: Arcana.Graph.GraphExtractor.LLM
  ]

config :lidl_chef, :llm,
  base_url: System.get_env("LM_STUDIO_URL", "http://127.0.0.1:1234"),
  model: "qwen/qwen3-4b-2507",
  timeout: 600_000

config :lidl_chef, :embedder,
  base_url: System.get_env("LM_STUDIO_URL", "http://127.0.0.1:1234"),
  model: "text-embedding-qwen3-embedding-0.6b",
  timeout: 120_000

config :lidl_chef, :reranker,
  base_url: System.get_env("LM_STUDIO_URL", "http://127.0.0.1:1234"),
  model: "qwen3-reranker-0.6b",
  threshold: 5,
  timeout: :infinity

# LLM DB
config :llm_db,
  custom: %{
    openai: [
      name: "LLaMA.cpp",
      base_url: System.get_env("LLAMA_CPP_URL", "http://localhost:8080"),
      models: %{
        "Qwen3.5-35B-A3B-Q5_K_M:Instruct-General" => %{
          capabilities: %{chat: true, streaming: %{text: true}}
        },
        "Qwen3-Next-80B-A3B-Instruct-UD-Q4_K_XL" => %{
          capabilities: %{chat: true, streaming: %{text: true}}
        }
      }
    ],
    openai: [
      name: "LM Studio",
      base_url: System.get_env("LM_STUDIO_URL", "http://localhost:1234"),
      models: %{
        "qwen/qwen3-4b-2507" => %{capabilities: %{chat: true, streaming: %{text: true}}},
        "qwen/qwen3-4b-thinking-2507" => %{capabilities: %{chat: true, streaming: %{text: true}}},
        "qwen3-4b-instruct-2507" => %{capabilities: %{chat: true, streaming: %{text: true}}},
        "qwen3-reranker-0.6b" => %{capabilities: %{chat: true}},
        "text-embedding-qwen3-embedding-0.6b" => %{capabilities: %{embeddings: true}}
      }
    ]
  }

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
