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
    # Translate this prompt to spanish, but not the entities, relationship types or output format
    """
    Del catalogo de productos de LIDL, extrae entidades y relaciones de esta entrada del catalogo de productos.
    From the LIDL product catalog, extract entities and relationships from this product catalog entry.

    ## Texto a analizar:
    #{text}

    ## Tipos de entidades para el catalogo de productos

    EXTRAE SOLO ESTOS TIPOS DE ENTIDADES:
    - wawiId: Identificador interno del producto, es un identificador numerico y viene en el campo `wawi_id` del texto del producto.
    - productTitle: El título de un producto. Múltiples erpNames pueden compartir el mismo título.
    - brand: Nombre de la marca o fabricante si se menciona
    - ingredient: Ingredientes individuales (ejemplo, "harina de trigo", "azúcar", "aceite de girasol")
    - allergen: Alérgenos presentes en el producto (ejemplo, "gluten", "leche", "huevos", "frutos de cáscara")
    - origin: Origen geográfico o lugar de producción (ejemplo, "España", "Andalucía")
    - certification: Certificaciones o estándares de calidad (ejemplo, "RSPO", "Ecológico", "ISO")
    - category: Categoría o línea de producto (ejemplo, "Alimentación", "Panadería", "Fresco")
    - identifier: Códigos o identificadores internos del producto (Cualquier identificador que no sea el wawiId)
    - nutrient: Componentes nutricionales o declaraciones (ejemplo, "proteínas", "carbohidratos")

    La entidad de tipo wawiId es la entidad principal del producto y debe incluir en sus metadatos el `productErpName` que es el nombre del producto en el ERP de Lidl.
    No extraigas metadatos para otra entidad que no sea el wawiId.
    No extraigas entidades que no estén claramente identificadas en el texto. Si no se menciona una entidad, no la inventes.
    No extraigas entidad para `productErpName`, ese es un metadato que se asocia a la entidad con tipo `wawiId` y se muestra al usuario, pero no es una entidad en sí misma.

    ## Tipos de relaciones a extraer

    EXTRAE SOLO ESTOS TIPOS DE RELACIONES:
    - HAS_BRAND: El producto tiene una marca específica
    - HAS_TITLE: Relación de ProductErpName a ProductTitle
    - HAS_ERP_NAME: La entidad ProductTitle tiene un erpName específico
    - CONTAINS_INGREDIENT: El producto contiene un ingrediente específico
    - CONTAINS_ALLERGEN: El producto contiene un alérgeno (debe declararse)
    - CONTAINS: Relación general de contención
    - PRODUCED_IN: El producto se origina en una ubicación
    - HAS_CERTIFICATION: El producto tiene una certificación/estándar
    - BELONGS_TO_CATEGORY: El producto pertenece a una categoría
    - HAS_NUTRIENT: El producto contiene un componente nutricional
    - RELATED_TO: Relación general entre entidades

    Cada relación puede incluir metadatos adicionales si es relevante:
    - Por ejemplo, para la relación "USES_INGREDIENT", puede incluir la cantidad y unidad de la entidad ingrediente
    - Los nutrientes deben extrarse como entidad (proteinas, carbohidratos, grasas, calorías) con su valor asociado en los metadatos de la relación "HAS_NUTRIENT".
      - Por ejemplo: "25g de proteinas", la entidad proteinas (tipo nutriente) y en los metadatos de la relación HAS_NUTRIENT incluir {"value": 25, "unit": "g"}

    ## Instrucciones:
    1. Extrae la entidad principal del producto del título
    2. Identifica todos los ingredientes mencionados (especialmente en la sección INGREDIENTES o Detalles)
    3. Extrae los alérgenos (en la sección ALÉRGENOS o advertencias de alérgenos)
    4. Busca información de origen (país, región, lugar de producción)
    5. Extrae certificaciones (RSPO, etiquetas ecológicas, estándares de calidad)
    6. Identifica la categoría/línea de producto
    7. Extrae el Wawi ID u otros identificadores (de la línea "ID Interno").
      7.1 El wawiId en su metadata debe incluir el productErpName.
    8. Crea relaciones que muestren cómo se conectan las entidades
    9. Usa strength 9-10 para relaciones explícitas (contiene alérgeno, tiene ingrediente)
    10. Usa strength 6-8 para relaciones contextuales (producido en, pertenece a categoría)

    ## Output format:
    Return a JSON object with two arrays:

    ```json
    {
      "entities": [
        {
          "name": "Entity Name",
          "type": "type",
          "description": "Brief context",
          "metadata": {"some_metadata_key": "some_metadata_value", "another_key": 123}
        },
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
    Eres un asistente de extracción de entidades y relaciones para la construcción de un grafo de conocimiento del catálogo de productos. Tu tarea es extraer
    entidades (productos, ingredientes, alérgenos, marcas, orígenes) y sus relaciones a partir de descripciones de productos. Sé preciso y extrae solo entidades y
    relaciones claramente identificables. Concéntrate en la información de seguridad alimentaria como alérgenos e ingredientes.
    Devuelve siempre JSON válido.
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
      name: truncate_string(Map.get(entity, "name"), 250),
      type: normalize_type(Map.get(entity, "type")),
      description: Map.get(entity, "description"),
      metadata: Map.get(entity, "metadata", %{})
    }
  end

  @doc """
  Truncate a string to a maximum length to fit database column constraints.

  Entity names are limited to 255 characters in the database, so we truncate
  to 250 to be safe and add ellipsis if truncated.
  """
  defp truncate_string(nil, _max_length), do: nil

  defp truncate_string(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length - 3) <> "..."
    else
      str
    end
  end

  defp truncate_string(str, _max_length), do: str

  defp normalize_type(nil), do: "other"

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.replace(~r/[^a-z_]/, "")
  end

  defp normalize_type(_), do: "other"

  defp normalize_relationship(rel) when is_map(rel) do
    %{
      source: truncate_string(Map.get(rel, "source"), 250),
      target: truncate_string(Map.get(rel, "target"), 250),
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
