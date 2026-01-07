defmodule Mix.Tasks.LidlChef.LoadRecipes do
  @moduledoc """
  Mix task to load the Lidl recipe dataset into the RAG system.

  This task reads the CSV file at dataset/1500_lidl_recipes.csv,
  processes each recipe, and ingests them into Arcana with GraphRAG
  enabled for entity extraction.

  ## Usage

      # Load all recipes with default settings
      mix lidl_chef.load_recipes

      # Load with custom batch size
      mix lidl_chef.load_recipes --batch-size 100

      # Load without GraphRAG (faster, but no entity relationships)
      mix lidl_chef.load_recipes --no-graph

      # Clear existing recipes before loading
      mix lidl_chef.load_recipes --clear

  """
  use Mix.Task

  @shortdoc "Load Lidl recipes into the RAG system"

  @switches [
    batch_size: :integer,
    no_graph: :boolean,
    clear: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    # Start the application
    Mix.Task.run("app.start")

    # Wait for embedding service to be ready
    Mix.shell().info("Waiting for embedding service to start...")
    wait_for_embedder_ready()

    batch_size = Keyword.get(opts, :batch_size, 50)
    enable_graph = not Keyword.get(opts, :no_graph, false)
    clear_first = Keyword.get(opts, :clear, false)

    if clear_first do
      Mix.shell().info("Clearing existing recipe collection...")
      LidlChef.Recipes.clear_collection()
    end

    Mix.shell().info("""
    Loading Lidl recipes...
      Batch size: #{batch_size}
      GraphRAG: #{if enable_graph, do: "enabled", else: "disabled"}
    """)

    case LidlChef.Recipes.load_dataset(batch_size: batch_size, graph: enable_graph) do
      {:ok, result} ->
        Mix.shell().info("""

        ✅ Dataset loaded successfully!
          Total recipes: #{result.total}
          Ingested: #{result.ingested}
          Errors: #{result.errors}
        """)

        if result.errors > 0 do
          Mix.shell().info("\nErrors:")

          Enum.each(result.error_details, fn {title, reason} ->
            Mix.shell().info("  - #{title}: #{inspect(reason)}")
          end)
        end

      {:error, reason} ->
        Mix.shell().error("❌ Failed to load dataset: #{inspect(reason)}")
    end
  end

  defp wait_for_embedder_ready(retries \\ 30, delay \\ 1_000) do
    case test_embedder() do
      :ok ->
        Mix.shell().info("✅ Embedding service is ready!")
        :ok

      {:error, _reason} when retries > 0 ->
        Mix.shell().info("⏳ Embedding service not ready yet, retrying in #{div(delay, 1000)}s... (#{retries} attempts left)")
        Process.sleep(delay)
        wait_for_embedder_ready(retries - 1, delay)

      {:error, reason} ->
        Mix.shell().error("❌ Embedding service failed to start: #{inspect(reason)}")
        Mix.shell().error("""

        This usually means:
        1. The embedding model is downloading (first run takes time)
        2. Insufficient memory for the embedding model
        3. EXLA/Nx backend not properly configured

        Try running with a smaller model or check your system resources.
        """)
        System.halt(1)
    end
  end

  defp test_embedder do
    try do
      # Test embedding a simple text
      case Arcana.Embedder.embed(Arcana.Config.embedder(), "test", []) do
        {:ok, _embedding} -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, reason -> {:error, {:exit, reason}}
      error -> {:error, error}
    end
  end
end
