defmodule LidlChef.RecipeAssistant.RecipeSearch do
  alias LidlChef.{Recipes, Repo, Reranker, LLM}
  alias Arcana.Agent
  require Logger

  @doc """
  Search for recipes based on a natural language query.

  This function:
  1. Extracts ingredients from the natural language query using LLM
  2. Searches the RAG with the extracted ingredients
  3. Reranks the recipes based on the original user query
  4. Returns recipes sorted by reranking first, then by RAG score
  """
  def run(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)
    temperature = Keyword.get(opts, :temperature, 0.3)

    Logger.debug("RecipeSearch: Starting search for query: #{query}")

    with {:ok, ingredients} <- extract_ingredients(query, temperature: temperature),
         {:ok, chunks} <- search_with_ingredients(ingredients, limit),
         {:ok, reranked_chunks} <- rerank_results(chunks, query, reranker_concurrency) do
      Logger.debug("RecipeSearch: Found #{length(reranked_chunks)} recipes")
      {:ok, reranked_chunks}
    else
      {:error, reason} = error ->
        Logger.error("RecipeSearch failed: #{inspect(reason)}")
        error
    end
  end

  defp extract_ingredients(query, opts) do
    Logger.debug("RecipeSearch: Extracting ingredients from query")

    prompt = """
    Extrae los ingredientes mencionados en la siguiente consulta del usuario.

    IMPORTANTE:
    - Devuelve SOLO los ingredientes separados por comas
    - NO incluyas explicaciones ni texto adicional
    - NO incluyas cantidades, medidas o utensilios
    - NO incluyas palabras como "receta", "cocinar", "preparar", "hacer"
    - Si no hay ingredientes claros, devuelve una lista vacía

    Consulta del usuario: "#{query}"

    Respuesta (solo ingredientes separados por comas):
    """

    case LLM.complete(prompt, opts) do
      {:ok, response} ->
        ingredients =
          response
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(&String.downcase/1)

        Logger.debug("RecipeSearch: Extracted ingredients: #{inspect(ingredients)}")

        if length(ingredients) > 0 do
          {:ok, ingredients}
        else
          Logger.debug("RecipeSearch: No ingredients extracted, falling back to direct search")
          {:err, :no_ingredients}
        end

      {:error, reason} ->
        Logger.warning("RecipeSearch: LLM extraction failed, falling back: #{inspect(reason)}")
        {:err, :no_ingredients}
    end
  end

  defp search_with_ingredients([], limit), do: search_direct("", limit)

  defp search_with_ingredients(ingredients, limit) do
    search_query = Enum.join(ingredients, " ")
    search_direct(search_query, limit)
  end

  defp search_direct(query, limit) do
    Logger.debug("RecipeSearch: Searching RAG with query: #{query}")

    case Recipes.search(query, limit: limit, graph: false, mode: :hybrid) do
      {:ok, chunks} when is_list(chunks) ->
        Logger.debug("RecipeSearch: RAG returned #{length(chunks)} chunks")
        {:ok, chunks}

      {:error, reason} ->
        Logger.error("RecipeSearch: RAG search failed: #{inspect(reason)}")
        {:error, {:search_failed, reason}}

      other ->
        Logger.error("RecipeSearch: Unexpected RAG response: #{inspect(other)}")
        {:error, :unexpected_response}
    end
  end

  defp rerank_results([], _query, _concurrency), do: {:ok, []}

  defp rerank_results(chunks, query, concurrency) do
    Logger.debug("RecipeSearch: Reranking #{length(chunks)} chunks")

    ctx = Agent.new(query, repo: Repo, limit: length(chunks))

    ctx = %{
      ctx
      | question: query,
        results: [
          %{
            question: query,
            collection: Recipes.collection_name(),
            chunks: chunks,
            iterations: 1
          }
        ]
    }

    reranked_ctx =
      Agent.rerank(ctx,
        reranker: Reranker
      )

    case reranked_ctx.results do
      [%{chunks: reranked_chunks} | _] ->
        Logger.debug("RecipeSearch: Reranked #{length(reranked_chunks)} chunks")
        {:ok, reranked_chunks}

      _ ->
        Logger.warning("RecipeSearch: Reranking failed, returning original results")
        {:ok, chunks}
    end
  end
end
