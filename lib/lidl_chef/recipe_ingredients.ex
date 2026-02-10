defmodule LidlChef.RecipeIngredients do
  @moduledoc """
  Helper module for extracting and enriching recipe ingredients from the knowledge graph.

  This module traverses the Arcana graph structure to:
  - Find recipe entities associated with chunks
  - Extract ingredients through USES_INGREDIENT relationships
  - Format ingredient information for display
  """

  alias LidlChef.Repo
  alias Arcana.{Chunk, Graph.Entity, Graph.EntityMention, Graph.Relationship}
  import Ecto.Query
  require Logger

  @doc """
  Extracts ingredients from a recipe chunk by traversing the knowledge graph.

  If the chunk has a recipe entity with USES_INGREDIENT relationships,
  returns `{:ok, ingredients}` where ingredients is a list of Entity structs.

  If no recipe entity exists or no ingredients are found, returns `{:ok, []}`.

  ## Examples

      iex> get_ingredients(chunk)
      {:ok, [%Entity{name: "tomate", type: "ingredient"}, ...]}

      iex> get_ingredients(non_recipe_chunk)
      {:ok, []}
  """
  def get_ingredients(%Chunk{id: chunk_id}) do
    chunk_id
    |> find_recipe_entity()
    |> traverse_ingredient_relationships()
    |> wrap_result()
  end

  def get_ingredients(%{id: chunk_id}) when is_binary(chunk_id) do
    Logger.debug("Processing map-based chunk with id: #{inspect(chunk_id, limit: :infinity)}")

    chunk_id
    |> find_recipe_entity()
    |> traverse_ingredient_relationships()
    |> wrap_result()
  end

  def get_ingredients(chunk) when is_map(chunk) do
    Logger.warning("Chunk without id field: #{inspect(Map.keys(chunk))}")
    {:ok, []}
  end

  def get_ingredients(_), do: {:ok, []}

  @doc """
  Formats a chunk with its ingredient information for display in prompts.

  If the chunk is a recipe with ingredients, appends a formatted list of
  available ingredients with their IDs for linking.
  """
  def format_chunk_with_ingredients(chunk) when is_map(chunk) do
    Logger.debug("Formatting chunk with ID: #{inspect(Map.get(chunk, :id))}")

    case get_ingredients(chunk) do
      {:ok, []} ->
        chunk.text

      {:ok, ingredients} ->
        ingredient_list = format_ingredient_list(ingredients)
        """
        #{chunk.text}

        🛒 Ingredientes disponibles en Lidl:
        #{ingredient_list}
        """
    end
  end

  @doc """
  Formats multiple chunks with their ingredient information.

  Useful for building context sections in LLM prompts.
  """
  def format_chunks_with_ingredients(chunks) when is_list(chunks) do
    chunks
    |> Enum.map(&format_chunk_with_ingredients/1)
    |> Enum.join("\n\n---\n\n")
  end

  @doc """
  Extracts all unique ingredients from a list of chunks.

  Returns a flat list of all ingredient entities found across the chunks.
  """
  def extract_all_ingredients(chunks) when is_list(chunks) do
    chunks
    |> Enum.flat_map(fn chunk ->
      case get_ingredients(chunk) do
        {:ok, ingredients} -> ingredients
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp find_recipe_entity(chunk_id) when is_binary(chunk_id) do
    uuid_string = Ecto.UUID.load!(chunk_id)

    Logger.debug("Looking for recipe entity with chunk_id: #{uuid_string}")

    query =
      from m in EntityMention,
        join: e in assoc(m, :entity),
        where: m.chunk_id == ^uuid_string,
        where: e.type == "receta",
        preload: [entity: {e, [source_relationships: :target]}]

    case Repo.all(query) do
      [] ->
        Logger.debug("No recipe entity found for chunk #{uuid_string}")
        nil

      [mention] ->
        entity = mention.entity
        Logger.debug("Found recipe entity: #{entity.name} with #{length(entity.source_relationships)} relationships")
        entity

      mentions ->
        entity = hd(mentions).entity
        Logger.debug("Found #{length(mentions)} recipe entities for chunk, using: #{entity.name}")
        entity
    end
  end

  defp find_recipe_entity(chunk_id) do
    Logger.warning("Unexpected chunk_id type: #{inspect(chunk_id)}")
    nil
  end

  defp traverse_ingredient_relationships(nil) do
    Logger.debug("No recipe entity found for chunk")
    []
  end

  defp traverse_ingredient_relationships(%Entity{source_relationships: relationships} = entity) do
    ingredients =
      relationships
      |> Enum.filter(&(&1.type == "USES_INGREDIENT"))
      |> Enum.map(& &1.target)
      |> Enum.reject(&is_nil/1)
      |> enrich_ingredients_with_erp()

    Logger.debug(
      "Recipe entity '#{entity.name}' has #{length(ingredients)} ingredients from #{length(relationships)} relationships"
    )

    ingredients
  end

  defp enrich_ingredients_with_erp(ingredients) do
    ingredients
    |> Enum.map(fn ingredient ->
      erp_products = fetch_erp_products(ingredient.id)

      Logger.debug("Ingredient '#{ingredient.name}' has #{length(erp_products)} ERP products")

      Map.put(ingredient, :erp_products, erp_products)
    end)
  end

  defp fetch_erp_products(ingredient_id) do
    forward_relationships =
      from(r in Relationship,
        where: r.source_id == ^ingredient_id and r.type == "HAS_ERP_NAME",
        preload: [:target]
      )
      |> Repo.all()
      |> Enum.map(& &1.target)
      |> Enum.reject(&is_nil/1)

    inverse_relationships =
      from(r in Relationship,
        where: r.target_id == ^ingredient_id and r.type == "HAS_TITLE",
        preload: [:source]
      )
      |> Repo.all()
      |> Enum.map(& &1.source)
      |> Enum.reject(&is_nil/1)

    (forward_relationships ++ inverse_relationships)
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(&(&1.type == "producterpname"))
    |> Enum.shuffle()
    |> Enum.take(3)
  end

  defp wrap_result(ingredients) when is_list(ingredients), do: {:ok, ingredients}

  defp format_ingredient_list(ingredients) do
    ingredients
    |> Enum.map(&format_single_ingredient/1)
    |> Enum.join("\n")
  end

  defp format_single_ingredient(%{name: name, id: id, erp_products: erp_products})
       when is_list(erp_products) and length(erp_products) > 0 do
    erp_list =
      erp_products
      |> Enum.map(fn erp ->
        "    - [#{erp.name}](http://localhost:4000/graph/#{erp.id})"
      end)
      |> Enum.join("\n")

    """
      • **#{name}** → [Ver ingrediente](http://localhost:4000/graph/#{id})
    #{erp_list}
    """
    |> String.trim_trailing()
  end

  defp format_single_ingredient(%{name: name, id: id, erp_products: _}) do
    "  • #{name} → [Ver ingrediente](http://localhost:4000/graph/#{id})"
  end

  defp format_single_ingredient(ingredient) do
    "  • #{ingredient.name} → [Ver ingrediente](http://localhost:4000/graph/#{ingredient.id})"
  end
end
