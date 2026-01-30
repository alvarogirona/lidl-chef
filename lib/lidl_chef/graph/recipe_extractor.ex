defmodule LidlChef.Graph.RecipeExtractor do
  @moduledoc """
  Custom LLM-based entity and relationship extractor for recipes.

  Specialized for extracting recipe-specific entities like ingredients,
  quantities, units, steps, and cooking methods from recipe text.

  ## Usage

      # Pass as extractor option when ingesting
      Arcana.ingest(text,
        repo: Repo,
        graph: true,
        extractor: LidlChef.Graph.RecipeExtractor
      )

  ## Configuration

      config :arcana, :graph,
        extractor: LidlChef.Graph.RecipeExtractor

  The LLM is automatically injected from the global `:arcana, :llm` config.
  """

  @behaviour Arcana.Graph.GraphExtractor

  @impl true
  def extract(text, opts) when is_binary(text) do
    llm = Keyword.fetch!(opts, :llm)
    prompt = build_recipe_extraction_prompt(text)

    :telemetry.span([:arcana, :graph, :extraction], %{text: text}, fn ->
      result =
        case Arcana.LLM.complete(llm, prompt, [], system_prompt: system_prompt()) do
          {:ok, response} ->
            parse_and_validate(response)

          {:error, reason} ->
            {:error, reason}
        end

      extracted_data_info =
        case result do
          {:ok, data} ->
            %{entity_count: length(data.entities), relationship_count: length(data.relationships)}

          {:error, _} ->
            %{entity_count: 0, relationship_count: 0}
        end

      {result, extracted_data_info}
    end)
  end

  def build_recipe_extraction_prompt(text) do
    """
    Extrae las siguientes entidades y relaciones del texto de la receta proporcionada:

    ## Receta a analizar:
    #{text}

    Entidades:
    - Receta: El nombre o título de la receta
    - productTitle: Ingrediente utilizado en la receta (por ejemplo, tomate, pollo, arroz)
    - Método de cocción (por ejemplo, hornear, freír, hervir)
    - Herramienta (por ejemplo, horno, sartén, batidora)
    - Categoría: Etiquetas o categorías de la receta (por ejemplo, "ensalada", "postre", "vegano")
    - Nutriente: Información nutricional (calorías, proteínas, carbohidratos, grasas)
    - Origin: País o región de origen de la receta, si está disponible

    Relaciones:
    - Relación "USES_INGREDIENT" entre Receta y productTitle
    - Relación "EMPLOYS_TOOL" entre Receta y Herramienta
    - Relación "APPLIES_METHOD" entre Receta y Método de cocción
    - Relación "BELONGS_TO_CATEGORY" entre Receta y Categoría
    - Relación "HAS_NUTRIENT" entre Receta y Nutriente
    - Relación "HAS_ORIGIN" entre Receta y Origin
    - `strength` (1-10): Indica la relevancia o importancia de la relación en el contexto de la receta.

    Cada relación puede incluir metadatos adicionales si es relevante:
    - Por ejemplo, para la relación "USES_INGREDIENT", puede incluir la cantidad y unidad de la entidad ingrediente
    - Los nutrientes deben extrarse como entidad (proteinas, carbohidratos, grasas, calorías) con su valor asociado en los metadatos de la relación "HAS_NUTRIENT".
      - Por ejemplo: "25g de proteinas", la entidad proteinas (tipo nutriente) y en los metadatos de la relación HAS_NUTRIENT incluir {"value": 25, "unit": "g"}

    ## Output format:
    Return a JSON object with two arrays:

    ```json
    {
      "entities": [
        {"name": "Entity Name", "type": "type", "description": "Brief context"}
      ],
      "relationships": [
        {
          "source": "Source Entity",
          "target": "Target Entity",
          "type": "RELATIONSHIP_TYPE",
          "description": "Brief description",
          "strength": 9,
          "metadata": {"some_metadata_key": "some_metadata_value", "another_key": 123}
        }
      ]
    }
    ```

    Return only the JSON object, no other text.
    """
  end

  defp system_prompt do
    """
    You are a recipe knowledge graph construction assistant. Your task is to extract
    entities (recipes, ingredients, cooking methods, tools, categories) and their relationships from
    recipe descriptions. Be precise and extract only clearly identifiable entities and
    relationships. Focus on ingredients, cooking techniques, and nutritional information.
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
      strength: normalize_strength(Map.get(rel, "strength")),
      metadata: Map.get(rel, "metadata", %{})
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
