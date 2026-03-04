defmodule LidlChef.DataIngestion.IngestProducts do
  @moduledoc """
  Module for processing and ingesting Lidl products into the RAG system.

  Extracts relevant fields from raw product JSON data and ingests
  them into the products collection for semantic search.

  Supports parallel processing and checkpointing for large datasets.
  """

  alias LidlChef.Products
  require Logger

  @checkpoint_file "priv/ingestion_checkpoint.json"

  @doc """
  Process and ingest a list of products.

  Each product is expected to have a "productData" key containing the product information.

  ## Options

    * `:batch_size` - Number of products to process in each batch (default: 50)
    * `:graph` - Enable GraphRAG entity extraction (default: true)
    * `:start_from` - Resume from index (0-based) or wawiId (default: 0)
    * `:resume` - Resume from last checkpoint (default: false)

  ## Returns

    `{:ok, %{total: n, ingested: n, errors: n, error_details: [...]}}`

  """
  @spec process_products(list(map()), keyword()) :: {:ok, map()}
  def process_products(products, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    enable_graph = Keyword.get(opts, :graph, true)
    start_from = Keyword.get(opts, :start_from, 0)
    resume = Keyword.get(opts, :resume, false)

    # Determine starting point
    start_index = if resume do
      case load_checkpoint() do
        {:ok, %{"next_index" => idx}} ->
          Logger.info("Resuming from checkpoint: index #{idx}")
          idx
        _ ->
          Logger.info("No checkpoint found, starting from beginning")
          0
      end
    else
      start_from
    end

    # Process products with checkpointing
    products
    |> Stream.with_index()
    |> Stream.drop(start_index)
    |> Stream.map(fn {product, idx} -> {extract_product_data(product), idx} end)
    |> Stream.filter(fn {product, _idx} -> product != nil end)
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce({0, 0, [], start_index}, fn batch, {total, ingested, errors, _last_idx} ->
      {batch_ingested, batch_errors, last_products} = ingest_batch_parallel(batch, enable_graph)

      # Get the last index from the batch
      {_product, last_idx} = List.last(batch)
      next_idx = last_idx + 1

      # Save checkpoint
      save_checkpoint(%{
        next_index: next_idx,
        last_products: last_products,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })

      Logger.info("Processed batch: #{batch_ingested} ingested, #{length(batch_errors)} errors. Checkpoint saved at index #{next_idx}")
      {total + length(batch), ingested + batch_ingested, errors ++ batch_errors, last_idx}
    end)
    |> then(fn {total, ingested, errors, _last_idx} ->
      Logger.info("Products loading complete: #{ingested}/#{total} products ingested")
      {:ok, %{total: total, ingested: ingested, errors: length(errors), error_details: errors}}
    end)
  end

  @doc """
  Extract relevant fields from a raw product map.

  Extracts:
  - `wawi_id` from `productData.wawiId`
  - `title` from `productData.texts.es.title`
  - `bullet_points` from `productData.texts.es.bulletPoints`
  - `product_line` from `productData.productLine`
  """
  @spec extract_product_data(map()) :: map() | nil
  def extract_product_data(%{"productData" => product_data}) do
    wawi_id = Map.get(product_data, "wawiId")
    product_line = Map.get(product_data, "productLine", "Unknown")

    texts = Map.get(product_data, "texts", %{})
    es_texts = Map.get(texts, "es", %{})
    title = Map.get(es_texts, "title")
    erpName = Map.get(es_texts, "erpName")
    bullet_points = Map.get(es_texts, "bulletPoints", [])

    # Skip products without essential data
    if wawi_id && title && erpName do
      %{
        wawi_id: wawi_id,
        title: title,
        erpName: erpName,
        bullet_points: bullet_points,
        product_line: product_line
      }
    else
      Logger.warning("Skipping product with missing wawi_id, title, or erpName: #{inspect(wawi_id)}")
      nil
    end
  end

  def extract_product_data(product) do
    Logger.warning("Skipping product without productData key: #{inspect(Map.keys(product))}")
    nil
  end

  defp ingest_batch_parallel(products_with_index, enable_graph) do
    concurrency = Application.get_env(:arcana, :graph, [])[:concurrency] || 6

    products_with_index
    |> Enum.chunk_every(concurrency)
    |> Enum.reduce({0, [], []}, fn product_batch, {count, errors, last_products} ->
      tasks =
        Enum.map(product_batch, fn {product, _idx} ->
          Task.async(fn ->
            case Products.ingest_product(product, enable_graph) do
              {:ok, _doc} -> {:ok, product}
              {:error, reason} -> {:error, product.title, reason}
            end
          end)
        end)

      results = Task.await_many(tasks, :infinity)

      Enum.reduce(results, {count, errors, last_products}, fn
        {:ok, product}, {c, e, lp} -> {c + 1, e, [%{wawi_id: product.wawi_id, title: product.title} | lp]}
        {:error, title, reason}, {c, e, lp} -> {c, [{title, reason} | e], lp}
      end)
    end)
  end

  @doc """
  Load the last checkpoint from the checkpoint file.
  """
  @spec load_checkpoint() :: {:ok, map()} | {:error, term()}
  def load_checkpoint do
    case File.read(@checkpoint_file) do
      {:ok, content} ->
        Jason.decode(content)

      {:error, :enoent} ->
        {:error, :no_checkpoint}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Save checkpoint information to file.
  """
  @spec save_checkpoint(map()) :: :ok | {:error, term()}
  def save_checkpoint(checkpoint_data) do
    # Ensure the directory exists
    checkpoint_dir = Path.dirname(@checkpoint_file)
    File.mkdir_p!(checkpoint_dir)

    case Jason.encode(checkpoint_data, pretty: true) do
      {:ok, json} ->
        File.write(@checkpoint_file, json)

      {:error, reason} ->
        Logger.error("Failed to encode checkpoint: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Clear the checkpoint file.
  """
  @spec clear_checkpoint() :: :ok
  def clear_checkpoint do
    File.rm(@checkpoint_file)
    :ok
  end
end
