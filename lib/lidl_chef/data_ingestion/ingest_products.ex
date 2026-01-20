defmodule LidlChef.DataIngestion.IngestProducts do
  @moduledoc """
  Module for processing and ingesting Lidl products into the RAG system.

  Extracts relevant fields from raw product JSON data and ingests
  them into the products collection for semantic search.
  """

  alias LidlChef.Products
  require Logger

  @doc """
  Process and ingest a list of products.

  Each product is expected to have a "productData" key containing the product information.

  ## Options

    * `:batch_size` - Number of products to process in each batch (default: 50)
    * `:graph` - Enable GraphRAG entity extraction (default: true)

  ## Returns

    `{:ok, %{total: n, ingested: n, errors: n, error_details: [...]}}`

  """
  @spec process_products(list(map()), keyword()) :: {:ok, map()}
  def process_products(products, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    enable_graph = Keyword.get(opts, :graph, true)

    products
    |> Stream.map(&extract_product_data/1)
    |> Stream.filter(&(&1 != nil))
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce({0, 0, []}, fn batch, {total, ingested, errors} ->
      {batch_ingested, batch_errors} = ingest_batch(batch, enable_graph)
      Logger.info("Processed batch: #{batch_ingested} ingested, #{length(batch_errors)} errors")
      {total + length(batch), ingested + batch_ingested, errors ++ batch_errors}
    end)
    |> then(fn {total, ingested, errors} ->
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
    bullet_points = Map.get(es_texts, "bulletPoints", [])

    # Skip products without essential data
    if wawi_id && title do
      %{
        wawi_id: wawi_id,
        title: title,
        bullet_points: bullet_points,
        product_line: product_line
      }
    else
      Logger.warning("Skipping product with missing wawi_id or title: #{inspect(wawi_id)}")
      nil
    end
  end

  def extract_product_data(product) do
    Logger.warning("Skipping product without productData key: #{inspect(Map.keys(product))}")
    nil
  end

  defp ingest_batch(products, enable_graph) do
    products
    |> Enum.reduce({0, []}, fn product, {count, errors} ->
      case Products.ingest_product(product, enable_graph) do
        {:ok, _doc} ->
          {count + 1, errors}

        {:error, reason} ->
          {count, [{product.title, reason} | errors]}
      end
    end)
  end
end
