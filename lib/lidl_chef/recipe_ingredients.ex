defmodule LidlChef.RecipeIngredients do
  @moduledoc """
  Helper module for extracting and enriching recipe ingredients from the knowledge graph.

  This module traverses the Arcana graph structure to:
  - Find recipe entities associated with chunks
  - Extract ingredients through USES_INGREDIENT relationships
  - Format ingredient information for display
  """

  alias LidlChef.Repo
  alias Arcana.{Chunk, Graph.Entity}
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

  def get_ingredients(_), do: {:ok, []}

  @doc """
  Formats a chunk with its ingredient information for display in prompts.

  If the chunk is a recipe with ingredients, appends a formatted list of
  available ingredients with their IDs for linking.
  """
  def format_chunk_with_ingredients(%Chunk{} = chunk) do
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

  def format_chunk_with_ingredients(chunk), do: chunk.text

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

  # Private functions

  defp find_recipe_entity(chunk_id) do
    from(e in Entity,
      where: e.chunk_id == ^chunk_id and e.type == "recipe",
      preload: [source_relationships: :target]
    )
    |> Repo.one()
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

    Logger.debug(
      "Recipe entity '#{entity.name}' has #{length(ingredients)} ingredients from #{length(relationships)} relationships"
    )

    ingredients
  end

  defp wrap_result(ingredients) when is_list(ingredients), do: {:ok, ingredients}

  defp format_ingredient_list(ingredients) do
    ingredients
    |> Enum.map(fn ingredient ->
      "  • #{ingredient.name} → http://localhost:4000/graph/#{ingredient.id}"
    end)
    |> Enum.join("\n")
  end
end
