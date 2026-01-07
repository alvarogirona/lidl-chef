defmodule LidlChef.Recipes do
  @moduledoc """
  Context module for managing Lidl recipes and their embeddings.

  Handles loading recipes from the CSV dataset, generating embeddings,
  and building the knowledge graph for GraphRAG-enhanced retrieval.
  """

  alias LidlChef.Repo
  require Logger

  @collection "lidl_recipes"

  @doc """
  Load and ingest all recipes from the CSV dataset.

  This function reads the CSV file, processes each recipe, and ingests
  them into the RAG system with GraphRAG enabled for entity extraction.

  ## Options

    * `:batch_size` - Number of recipes to process in each batch (default: 50)
    * `:graph` - Enable GraphRAG entity extraction (default: true)

  ## Examples

      iex> LidlChef.Recipes.load_dataset()
      {:ok, %{total: 1500, ingested: 1500, errors: 0}}

  """
  @spec load_dataset(keyword()) :: {:ok, map()} | {:error, term()}
  def load_dataset(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    enable_graph = Keyword.get(opts, :graph, true)

    csv_path =
      Path.join([Application.app_dir(:lidl_chef), "..", "..", "dataset", "1500_lidl_recipes.csv"])

    # Normalize the path
    csv_path = Path.expand(csv_path)

    Logger.info("Loading recipes from #{csv_path}")

    case File.exists?(csv_path) do
      true ->
        process_csv_file(csv_path, batch_size, enable_graph)

      false ->
        # Try alternative path for development
        alt_path = "dataset/1500_lidl_recipes.csv"

        if File.exists?(alt_path) do
          process_csv_file(alt_path, batch_size, enable_graph)
        else
          {:error, {:file_not_found, csv_path}}
        end
    end
  end

  defp process_csv_file(csv_path, batch_size, enable_graph) do
    csv_path
    |> File.stream!()
    |> NimbleCSV.RFC4180.parse_stream(skip_headers: true)
    |> Stream.map(&parse_recipe_row/1)
    |> Stream.filter(&(&1 != nil))
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce({0, 0, []}, fn batch, {total, ingested, errors} ->
      {batch_ingested, batch_errors} = ingest_batch(batch, enable_graph)
      Logger.info("Processed batch: #{batch_ingested} ingested, #{length(batch_errors)} errors")
      {total + length(batch), ingested + batch_ingested, errors ++ batch_errors}
    end)
    |> then(fn {total, ingested, errors} ->
      Logger.info("Dataset loading complete: #{ingested}/#{total} recipes ingested")
      {:ok, %{total: total, ingested: ingested, errors: length(errors), error_details: errors}}
    end)
  end

  defp parse_recipe_row([
         title,
         url,
         servings,
         ingredients,
         calories,
         carbs,
         proteins,
         fats,
         tags
       ]) do
    %{
      title: title,
      url: url,
      servings: servings,
      ingredients: parse_json_list(ingredients),
      calories: calories,
      carbohydrates: carbs,
      proteins: proteins,
      fats: fats,
      tags: parse_json_list(tags)
    }
  rescue
    _ -> nil
  end

  defp parse_recipe_row(_), do: nil

  defp parse_json_list(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp parse_json_list(_), do: []

  defp ingest_batch(recipes, enable_graph) do
    recipes
    |> Enum.reduce({0, []}, fn recipe, {count, errors} ->
      case ingest_recipe(recipe, enable_graph) do
        {:ok, _doc} ->
          {count + 1, errors}

        {:error, reason} ->
          {count, [{recipe.title, reason} | errors]}
      end
    end)
  end

  @doc """
  Ingest a single recipe into the RAG system.

  Creates a rich text representation of the recipe including title,
  ingredients, nutritional information, and tags for better semantic search.
  """
  @spec ingest_recipe(map(), boolean()) :: {:ok, term()} | {:error, term()}
  def ingest_recipe(recipe, enable_graph \\ true) do
    content = format_recipe_for_embedding(recipe)

    metadata = %{
      "title" => recipe.title,
      "url" => recipe.url,
      "servings" => recipe.servings,
      "calories" => recipe.calories,
      "carbohydrates" => recipe.carbohydrates,
      "proteins" => recipe.proteins,
      "fats" => recipe.fats,
      "tags" => Enum.join(recipe.tags, ", "),
      "ingredients_list" => Enum.join(recipe.ingredients, ", ")
    }

    Arcana.ingest(content,
      repo: Repo,
      collection: @collection,
      metadata: metadata,
      graph: enable_graph
    )
  end

  defp format_recipe_for_embedding(recipe) do
    ingredients_text =
      recipe.ingredients
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    tags_text = Enum.join(recipe.tags, ", ")

    nutrition_text =
      [
        if(recipe.calories != "N/A", do: "Calories: #{recipe.calories}"),
        if(recipe.carbohydrates != "N/A", do: "Carbohydrates: #{recipe.carbohydrates}"),
        if(recipe.proteins != "N/A", do: "Proteins: #{recipe.proteins}"),
        if(recipe.fats != "N/A", do: "Fats: #{recipe.fats}")
      ]
      |> Enum.filter(&(&1 != nil))
      |> Enum.join(", ")

    """
    Recipe: #{recipe.title}

    Servings: #{recipe.servings}

    Ingredients:
    #{ingredients_text}

    #{if nutrition_text != "", do: "Nutrition: #{nutrition_text}\n", else: ""}
    Categories: #{tags_text}

    URL: #{recipe.url}
    """
  end

  @doc """
  Search for recipes based on a natural language query.

  Uses hybrid search (vector + fulltext) with optional GraphRAG
  for enhanced retrieval through entity relationships.

  ## Options

    * `:limit` - Maximum number of results (default: 10)
    * `:graph` - Enable GraphRAG search (default: true)
    * `:mode` - Search mode `:semantic`, `:fulltext`, or `:hybrid` (default: :hybrid)

  ## Examples

      iex> LidlChef.Recipes.search("chicken with vegetables")
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
  Get recipe recommendations based on available ingredients.

  Searches for recipes that can be made with the given ingredients
  and returns them ranked by relevance.

  ## Examples

      iex> LidlChef.Recipes.find_by_ingredients(["chicken", "tomato", "onion"])
      {:ok, [%{...}, ...]}

  """
  @spec find_by_ingredients(list(String.t()), keyword()) :: {:ok, list(map())} | {:error, term()}
  def find_by_ingredients(ingredients, opts \\ []) when is_list(ingredients) do
    limit = Keyword.get(opts, :limit, 10)

    query = """
    Recipes that can be made with: #{Enum.join(ingredients, ", ")}.
    Looking for dishes that use these ingredients as main components.
    """

    search(query, limit: limit, graph: true, mode: :hybrid)
  end

  @doc """
  Delete all recipes from the collection.

  Useful for re-ingesting the dataset with different settings.
  """
  @spec clear_collection() :: :ok | {:error, term()}
  def clear_collection do
    import Ecto.Query

    # Delete all documents in the collection
    query = from d in Arcana.Document, where: d.collection == ^@collection

    case Repo.delete_all(query) do
      {count, _} ->
        Logger.info("Deleted #{count} documents from recipe collection")
        :ok

      error ->
        Logger.error("Failed to clear collection: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Get statistics about the recipe collection.
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
  Returns the collection name used for recipes.
  """
  @spec collection_name() :: String.t()
  def collection_name, do: @collection
end
