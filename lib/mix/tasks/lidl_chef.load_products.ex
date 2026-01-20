defmodule Mix.Tasks.LidlChef.LoadProducts do
  @moduledoc """
  Mix task to load the Lidl products dataset into the RAG system.

  This task reads the JSON file at dataset/products.json,
  processes each product, and ingests them into Arcana with GraphRAG
  enabled for entity extraction.

  ## Usage

      # Load all products with default settings
      mix lidl_chef.load_products

      # Load with custom batch size
      mix lidl_chef.load_products --batch-size 100

      # Load without GraphRAG (faster, but no entity relationships)
      mix lidl_chef.load_products --no-graph

      # Clear existing products before loading
      mix lidl_chef.load_products --clear

  """
  use Mix.Task

  alias LidlChef.DataIngestion.IngestProducts

  @shortdoc "Load Lidl products into the RAG system"

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
      Mix.shell().info("Clearing existing products collection...")
      LidlChef.Products.clear_collection()
    end

    Mix.shell().info("""
    Loading Lidl products...
      Batch size: #{batch_size}
      GraphRAG: #{if enable_graph, do: "enabled", else: "disabled"}
    """)

    case load_products_from_json(batch_size, enable_graph) do
      {:ok, result} ->
        Mix.shell().info("""

        ✅ Products loaded successfully!
          Total products: #{result.total}
          Ingested: #{result.ingested}
          Errors: #{result.errors}
        """)

        if result.errors > 0 do
          Mix.shell().info("\nErrors:")

          Enum.take(result.error_details, 10)
          |> Enum.each(fn {title, reason} ->
            Mix.shell().info("  - #{title}: #{inspect(reason)}")
          end)

          if result.errors > 10 do
            Mix.shell().info("  ... and #{result.errors - 10} more errors")
          end
        end

      {:error, reason} ->
        Mix.shell().error("❌ Failed to load products: #{inspect(reason)}")
    end
  end

  defp load_products_from_json(batch_size, enable_graph) do
    json_path = find_products_json_path()

    Mix.shell().info("Loading products from #{json_path}")

    case File.read(json_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, products} when is_list(products) ->
            Mix.shell().info("Found #{length(products)} products in JSON file")
            IngestProducts.process_products(products, batch_size: batch_size, graph: enable_graph)

          {:ok, _} ->
            {:error, :invalid_json_structure}

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp find_products_json_path do
    # Try development path first
    dev_path = "dataset/products.json"

    if File.exists?(dev_path) do
      dev_path
    else
      # Try application directory path
      Path.join([Application.app_dir(:lidl_chef), "..", "..", "dataset", "products.json"])
      |> Path.expand()
    end
  end

  defp wait_for_embedder_ready(retries \\ 30, delay \\ 1_000) do
    case test_embedder() do
      :ok ->
        Mix.shell().info("✅ Embedding service is ready!")
        :ok

      {:error, _reason} when retries > 0 ->
        Mix.shell().info(
          "⏳ Embedding service not ready yet, retrying in #{div(delay, 1000)}s... (#{retries} attempts left)"
        )

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
