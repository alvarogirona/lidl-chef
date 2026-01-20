defmodule LidlChef.Graph.ProductExtractor do
  @moduledoc """
  Custom LLM-based entity and relationship extractor for product catalog.

  Specialized for extracting product-specific entities like ingredients,
  allergens, brands, origins, and certifications from Lidl product data.

  ## Usage

      # Pass as extractor option when ingesting
      Arcana.ingest(text,
        repo: Repo,
        graph: true,
        extractor: LidlChef.Graph.ProductExtractor
      )

  ## Configuration

      config :arcana, :graph,
        extractor: LidlChef.Graph.ProductExtractor

  The LLM is automatically injected from the global `:arcana, :llm` config.
  """

  @behaviour Arcana.Graph.GraphExtractor

  @impl true
  def extract(text, opts) when is_binary(text) do
    llm = Keyword.fetch!(opts, :llm)
    prompt = build_product_extraction_prompt(text)

    :telemetry.span([:arcana, :graph, :extraction], %{text: text}, fn ->
      result =
        case Arcana.LLM.complete(llm, prompt, [], system_prompt: system_prompt()) do
          {:ok, response} ->
            parse_and_validate(response)

          {:error, reason} ->
            {:error, reason}
        end

      metadata =
        case result do
          {:ok, data} ->
            %{entity_count: length(data.entities), relationship_count: length(data.relationships)}

          {:error, _} ->
            %{entity_count: 0, relationship_count: 0}
        end

      {result, metadata}
    end)
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
    From a LIDL product catalog entry, extract entities and relationships from this product catalog entry.

    ## Text to analyze:
    #{text}

    ## Entity types for product catalog:
    - wawiId: Internal product identifier
    - productErpName: The main product based on its erpName (e.g., "Croissant brioche", "Ensalada de pasta rúcula"). A product with the same wawiId may have multiple erpNames.
    - productTitle: The title of a product. A product with the same wawiId may have multiple titles.
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
    - HAS_TITLE: Product has a specific title
    - HAS_ERP_NAME: Product has a specific erpName
    - BRAND_OF: Brand is the brand of the product
    - HAS_BRAND: Product has a specific brand
    - HAS_WAWI_ID: Product has a specific wawiId
    - RELATED_TO: General relationship between entities
    - CONTAINS: General containment relationship

    ## Instructions:
    1. Extract the main product entity from the title
    2. Identify all ingredients mentioned (especially in INGREDIENTES or Details section)
    3. Extract allergens (in ALÉRGENOS section or allergen warnings)
    4. Look for origin information (country, region, production location)
    5. Extract certifications (RSPO, organic labels, quality standards)
    6. Identify the product category/line
    7. Extract the Wawi ID or other identifiers (from "Internal ID" line)
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

  defp system_prompt do
    """
    You are a product catalog knowledge graph construction assistant. Your task is to extract
    entities (products, ingredients, allergens, brands, origins) and their relationships from
    product descriptions. Be precise and extract only clearly identifiable entities and
    relationships. Focus on food safety information like allergens and ingredients.
    Always return valid JSON.
    """
  end

  defp parse_and_validate(response) do
    cleaned =
      response
      |> String.trim()
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"entities" => entities, "relationships" => relationships}}
      when is_list(entities) and is_list(relationships) ->
        normalized_entities = Enum.map(entities, &normalize_entity/1)
        entity_names = MapSet.new(normalized_entities, & &1.name)

        validated_relationships =
          relationships
          |> Enum.map(&normalize_relationship/1)
          |> Enum.filter(&valid_relationship?(&1, entity_names))

        {:ok, %{entities: normalized_entities, relationships: validated_relationships}}

      {:ok, _} ->
        {:error,
         {:json_parse_error, "Expected object with 'entities' and 'relationships' arrays"}}

      {:error, error} ->
        {:error, {:json_parse_error, error}}
    end
  end

  defp normalize_entity(entity) when is_map(entity) do
    %{
      name: Map.get(entity, "name"),
      type: normalize_type(Map.get(entity, "type")),
      description: Map.get(entity, "description")
    }
  end

  defp normalize_type(nil), do: "other"

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.replace(~r/[^a-z_]/, "")
  end

  defp normalize_type(_), do: "other"

  defp normalize_relationship(rel) when is_map(rel) do
    %{
      source: Map.get(rel, "source"),
      target: Map.get(rel, "target"),
      type: normalize_relationship_type(Map.get(rel, "type")),
      description: Map.get(rel, "description"),
      strength: normalize_strength(Map.get(rel, "strength"))
    }
  end

  defp normalize_relationship_type(nil), do: "RELATED_TO"

  defp normalize_relationship_type(type) when is_binary(type) do
    type
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp normalize_relationship_type(_), do: "RELATED_TO"

  defp normalize_strength(nil), do: nil

  defp normalize_strength(strength) when is_integer(strength) do
    strength
    |> max(1)
    |> min(10)
  end

  defp normalize_strength(strength) when is_binary(strength) do
    case Integer.parse(strength) do
      {val, _} -> normalize_strength(val)
      :error -> nil
    end
  end

  defp normalize_strength(_), do: nil

  defp valid_relationship?(%{source: source, target: target, type: type}, entity_names) do
    is_binary(source) and
      is_binary(target) and
      is_binary(type) and
      source != target and
      MapSet.member?(entity_names, source) and
      MapSet.member?(entity_names, target)
  end
end
