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
      "product_line" => product.product_line,
      "bullet_points" => Enum.join(product.bullet_points || [], "\n")
    }

    Arcana.ingest(content,
      repo: Repo,
      collection: @collection,
      metadata: metadata,
      graph: enable_graph,
      prompt: build_product_extraction_prompt(content)
    )
  end

  @doc """
  Builds a custom extraction prompt for product catalog entities and relationships.

  Focuses on extracting:
  - Product entity (name/title)
  - Brand information
  - Ingredients
  - Allergens
  - Origin (country/region)
  - Product identifiers (Wawi ID)
  - Nutritional information
  - Certifications (e.g., RSPO, organic)
  """
  @spec build_product_extraction_prompt(String.t()) :: String.t()
  def build_product_extraction_prompt(text) do
    """
    Extrae las entidades y relaciones del siguiente texto de un producto de Lidl.

    ## Text to analyze:
    #{text}

    ## Entity types for product catalog:
    - product: The main product name/title (e.g., "Croissant brioche", "Ensalada de pasta rúcula")
    - brand: Brand or manufacturer name if mentioned
    - ingredient: Individual ingredients (e.g., "harina de trigo", "azúcar", "aceite de girasol")
    - allergen: Allergens present in the product (e.g., "gluten", "leche", "huevos", "frutos de cáscara")
    - origin: Geographic origin or production location (e.g., "España", "Andalucía")
    - certification: Certifications or quality standards (e.g., "RSPO", "Ecológico", "ISO")
    - category: Product category or line (e.g., "Food", "Bakery", "Fresh")
    - identifier: Internal product codes or identifiers (e.g., Wawi ID)
    - nutrient: Nutritional components or claims (e.g., "proteínas", "carbohidratos")

    ## Relationship types to extract:
    - CONTAINS_INGREDIENT: Product contains a specific ingredient
    - CONTAINS_ALLERGEN: Product contains an allergen (must declare)
    - PRODUCED_IN: Product originates from a location
    - HAS_CERTIFICATION: Product has a certification/standard
    - BELONGS_TO_CATEGORY: Product belongs to a category
    - IDENTIFIED_BY: Product identified by code/ID
    - HAS_NUTRIENT: Product contains nutritional component

    ## Instructions:
    1. Extract the main product entity from the title
    2. Identify all ingredients mentioned (especially in INGREDIENTES section)
    3. Extract allergens (in ALÉRGENOS section or allergen warnings)
    4. Look for origin information (country, region, production location)
    5. Extract certifications (RSPO, organic labels, quality standards)
    6. Identify the product category/line
    7. Extract the Wawi ID or other identifiers
    8. Create relationships showing how entities connect
    9. Use strength 9-10 for explicit relationships (contains allergen, has ingredient)
    10. Use strength 6-8 for contextual relationships (produced in, belongs to category)

    ## Important Spanish terms to recognize:
    - "INGREDIENTES" = ingredients list
    - "ALÉRGENOS" = allergens
    - "contiene" = contains
    - "puede contener" = may contain
    - "sin" = without
    - "procedente de" = from/originating from

    ## Output format:
    Return a JSON object with two arrays:

    ```json
    {
      "entities": [
        {"name": "Entity Name", "type": "type", "description": "Brief context"}
      ],
      "relationships": [
        {"source": "Source Entity", "target": "Target Entity", "type": "RELATIONSHIP_TYPE", "description": "Brief description", "strength": 9}
      ]
    }
    ```

    Return only the JSON object, no other text.
    """
  end

  defp format_product_for_embedding(product) do
    bullet_points_text =
      (product.bullet_points || [])
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    """
    Product: #{product.title}

    Product Line: #{product.product_line}

    #{if bullet_points_text != "", do: "Details:\n#{bullet_points_text}\n", else: ""}
    Internal ID: #{product.wawi_id}
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
      graph: enable_graph
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
