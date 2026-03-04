defmodule LidlChef.Products do
  @moduledoc """
  Context module for managing Lidl products and their embeddings.

  Handles loading products from JSON dataset, generating embeddings,
  and ingesting them into the RAG system for semantic search.
  """

  alias LidlChef.Repo
  require Logger

  @collection "products"

  @doc """
  Ingest a single product into the RAG system.

  Creates a text representation of the product including title,
  bullet points (ingredients/allergens), and product line for semantic search.

  ## Parameters

    * `product` - Map with extracted product fields:
      - `:wawi_id` - Internal product ID
      - `:title` - Product title
      - `:bullet_points` - List of bullet points (ingredients, allergens, etc.)
      - `:product_line` - Product type (e.g., "Food")

    * `enable_graph` - Enable GraphRAG entity extraction (default: false)

  ## Examples

      iex> LidlChef.Products.ingest_product(%{wawi_id: "123", title: "Croissant", ...})
      {:ok, _doc}

  """
  @spec ingest_product(map(), boolean()) :: {:ok, term()} | {:error, term()}
  def ingest_product(product, enable_graph \\ false) do
    content = format_product_for_embedding(product)

    metadata = %{
      "wawi_id" => product.wawi_id,
      "title" => product.title,
      "erpName" => product.erpName,
      "product_line" => product.product_line,
      "bullet_points" => Enum.join(product.bullet_points || [], "\n")
    }

    Arcana.ingest(content,
      repo: Repo,
      collection: @collection,
      metadata: metadata,
      graph: enable_graph,
      extractor: {LidlChef.Graph.ProductExtractor, []}
    )
  end

  defp format_product_for_embedding(product) do
    bullet_points_text =
      (product.bullet_points || [])
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    """
    Product ERP name: #{product.erpName}

    Product title: #{product.title}

    Product Line: #{product.product_line}

    #{if bullet_points_text != "", do: "Details:\n#{bullet_points_text}\n", else: ""}

    wawi_id: #{product.wawi_id}
    """
  end

  @doc """
  Search for products based on a natural language query.

  Uses hybrid search (vector + fulltext) with optional GraphRAG
  for enhanced retrieval through entity relationships.

  ## Options

    * `:limit` - Maximum number of results (default: 10)
    * `:graph` - Enable GraphRAG search (default: true)
    * `:mode` - Search mode `:semantic`, `:fulltext`, or `:hybrid` (default: :hybrid)

  ## Examples

      iex> LidlChef.Products.search("croissant")
      {:ok, [%{...}, ...]}

  """
  @spec search(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    enable_graph = Keyword.get(opts, :graph, true)
    mode = Keyword.get(opts, :mode, :hybrid)

    Arcana.search(query,
      repo: Repo,
      collection: @collection,
      limit: limit,
      mode: mode,
      graph: enable_graph,
      entity_extractor: {LidlChef.Graph.ProductSearchEntityExtractor, []}
    )
  end

  @doc """
  Delete all products from the collection.

  Useful for re-ingesting the dataset with different settings.
  """
  @spec clear_collection() :: :ok | {:error, term()}
  def clear_collection do
    import Ecto.Query

    query = from d in Arcana.Document, where: d.collection == ^@collection

    case Repo.delete_all(query) do
      {count, _} ->
        Logger.info("Deleted #{count} documents from products collection")
        :ok

      error ->
        Logger.error("Failed to clear collection: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Get statistics about the products collection.
  """
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    import Ecto.Query

    doc_count =
      Repo.aggregate(
        from(d in Arcana.Document, where: d.collection == ^@collection),
        :count
      )

    chunk_count =
      Repo.aggregate(
        from(c in Arcana.Chunk,
          join: d in Arcana.Document,
          on: c.document_id == d.id,
          where: d.collection == ^@collection
        ),
        :count
      )

    {:ok,
     %{
       collection: @collection,
       documents: doc_count,
       chunks: chunk_count
     }}
  end

  @doc """
  Returns the collection name used for products.
  """
  @spec collection_name() :: String.t()
  def collection_name, do: @collection
end
