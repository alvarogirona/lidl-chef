defmodule LidlChef.RecipeAssistant.DietarySearch do
  alias LidlChef.{LLM, Recipes, Repo, Reranker, RecipeIngredients}
  alias Arcana.Agent
  require Logger

  @recipes_per_query 10
  @selection_multiplier 3

  def run(question, intent_info, opts) do
    limit = Keyword.get(opts, :limit, 10)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)
    search_fn = Keyword.get(opts, :search_fn, &default_search/2)

    chunks =
      search_and_rerank(
        question,
        intent_info,
        limit * @selection_multiplier,
        search_fn,
        reranker_concurrency,
        !skip_rerank
      )

    Logger.debug("[DietarySearch] Found #{length(chunks)} recipes for: #{inspect(intent_info)}")

    prompt_fn = fn _question, _chunks -> build_dietary_prompt(chunks, question, intent_info) end

    ctx =
      Agent.new(question, repo: Repo, limit: length(chunks))
      |> Map.put(:question, question)
      |> Map.put(:results, [
        %{
          question: question,
          collection: Recipes.collection_name(),
          chunks: chunks,
          iterations: 1
        }
      ])

    ctx
    |> Agent.answer(
      repo: Repo,
      prompt: prompt_fn
    )
    |> handle_answer()
  end

  def run_stream(question, intent_info, on_chunk, opts) when is_function(on_chunk, 1) do
    limit = Keyword.get(opts, :limit, 10)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)
    search_fn = Keyword.get(opts, :search_fn, &default_search/2)

    chunks =
      search_and_rerank(
        question,
        intent_info,
        limit * @selection_multiplier,
        search_fn,
        reranker_concurrency,
        !skip_rerank
      )

    Logger.debug("[DietarySearch] Found #{length(chunks)} recipes for stream")

    build_dietary_prompt(chunks, question, intent_info)
    |> LLM.stream(on_chunk, opts)
  end

  defp search_and_rerank(question, intent_info, target_count, search_fn, concurrency, do_rerank) do
    queries = build_dietary_queries(intent_info)

    Logger.debug("[DietarySearch] Running #{length(queries)} queries for dietary search")

    chunks =
      queries
      |> Enum.flat_map(fn query ->
        search_single(query, @recipes_per_query, search_fn)
      end)
      |> deduplicate_chunks()

    Logger.debug("[DietarySearch] Found #{length(chunks)} unique recipes")

    reranked_chunks =
      if do_rerank and length(chunks) > 0 do
        rerank_query = build_rerank_query(question, intent_info)
        rerank_chunks(chunks, rerank_query, concurrency)
      else
        Logger.debug("[DietarySearch] Skipping rerank (do_rerank=#{do_rerank})")
        chunks
      end

    final_chunks = Enum.take(reranked_chunks, target_count)

    Logger.info(
      "[DietarySearch] Selected #{length(final_chunks)} recipes (from #{length(chunks)} found)"
    )

    final_chunks
  end

  defp build_dietary_queries(%{dietary: dietary, meal_type: meal_type, ingredients: ingredients, attributes: attributes}) do
    base_queries = build_base_queries(dietary, meal_type, attributes)
    ingredient_queries = build_ingredient_queries(dietary, meal_type, ingredients)

    (base_queries ++ ingredient_queries)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp build_base_queries(dietary, meal_type, attributes) do
    dietary_term = if dietary, do: dietary, else: ""
    meal_term = if meal_type, do: meal_type, else: ""

    base = [
      "#{dietary_term} #{meal_term}",
      "receta #{dietary_term} #{meal_term}",
      "#{dietary_term} saludable #{meal_term}"
    ]

    attribute_queries =
      if attributes && length(attributes) > 0 do
        Enum.map(attributes, fn attr ->
          "#{dietary_term} #{meal_term} #{attr}"
        end)
      else
        []
      end

    (base ++ attribute_queries)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp build_ingredient_queries(dietary, meal_type, ingredients) when is_list(ingredients) and length(ingredients) > 0 do
    dietary_term = if dietary, do: dietary, else: ""
    meal_term = if meal_type, do: meal_type, else: ""

    # Create queries with combinations of ingredients
    single_ingredient = Enum.take(ingredients, 3) |> Enum.map(fn ing ->
      "#{dietary_term} #{meal_term} #{ing}"
    end)

    # Create queries with pairs of ingredients
    pairs =
      if length(ingredients) >= 2 do
        ingredients
        |> Enum.take(4)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [ing1, ing2] ->
          "#{dietary_term} #{meal_term} #{ing1} #{ing2}"
        end)
      else
        []
      end

    # Create query with all ingredients (up to 3)
    all_ingredients =
      if length(ingredients) > 0 do
        ing_list = ingredients |> Enum.take(3) |> Enum.join(" ")
        ["#{dietary_term} #{meal_term} #{ing_list}"]
      else
        []
      end

    (single_ingredient ++ pairs ++ all_ingredients)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp build_ingredient_queries(_, _, _), do: []

  defp build_rerank_query(question, %{dietary: dietary, meal_type: meal_type}) do
    dietary_context = if dietary, do: ", preferencia: #{dietary}", else: ""
    meal_context = if meal_type, do: ", tipo de comida: #{meal_type}", else: ""

    "#{question}#{dietary_context}#{meal_context}"
  end

  defp rerank_chunks(chunks, query, concurrency) do
    {:ok, reranked} =
      Reranker.rerank(query, chunks,
        threshold: 2,
        concurrency: concurrency
      )

    Logger.debug("[DietarySearch] Reranked #{length(chunks)} -> #{length(reranked)} chunks")
    reranked
  end

  defp search_single(query, limit, search_fn) do
    cache_key = {:recipe_search, query, limit}
    ttl = :timer.hours(2)

    case Cachex.fetch(:recipe_search_cache, cache_key, fn _key ->
           with {:ok, chunks} <- search_fn.(query, limit) do
             {:commit, chunks, ttl: ttl}
           else
             _ -> {:ignore, []}
           end
         end) do
      {:ok, chunks} -> chunks
      {:commit, chunks} -> chunks
      _ -> fallback_search(query, limit, search_fn)
    end
  end

  defp fallback_search(query, limit, search_fn) do
    case search_fn.(query, limit) do
      {:ok, chunks} -> chunks
      _ -> []
    end
  end

  defp deduplicate_chunks(chunks) do
    Enum.uniq_by(chunks, &(&1.document_id || extract_title_from_chunk(&1.text)))
  end

  defp extract_title_from_chunk(text) do
    case Regex.run(~r/Recipe:\s*(.+?)(?:\n|$)/i, text) do
      [_, title] -> String.trim(title)
      _ -> text
    end
  end

  defp default_search(query, limit),
    do: Recipes.search(query, limit: limit, graph: false, mode: :hybrid)

  defp handle_answer(%{answer: answer}) when not is_nil(answer) do
    Logger.debug("After answer phase: Generated #{String.length(answer)} chars")
    {:ok, answer}
  end

  defp handle_answer(%{error: error}) do
    Logger.debug("After answer phase: NO ANSWER generated! Error: #{inspect(error)}")
    {:error, {:no_answer, "Agent did not generate an answer"}}
  end

  defp build_dietary_prompt(chunks, question, intent_info) do
    reference_material = RecipeIngredients.format_chunks_with_ingredients(chunks)
    dietary = intent_info.dietary || "especial"
    meal_type = intent_info.meal_type
    ingredients = intent_info.ingredients || []

    Logger.debug("Building dietary prompt: #{length(chunks)} chunks, dietary: #{dietary}, meal_type: #{meal_type}")

    meal_type_context =
      if meal_type do
        " para #{meal_type}"
      else
        ""
      end

    ingredients_context =
      if length(ingredients) > 0 do
        "\n⚠️ El usuario prefiere incluir estos ingredientes: #{Enum.join(ingredients, ", ")}"
      else
        ""
      end

    """
    Eres un asistente de Lidl Chef especializado en alimentación #{dietary}.

    ⚠️ RESPONDE SIEMPRE EN ESPAÑOL.

    El usuario busca recetas que sean #{dietary}#{meal_type_context}.#{ingredients_context}

    Tu tarea es:
    1. Revisar el CONTEXTO y encontrar recetas aptas para dieta #{dietary}
    2. Verificar que los ingredientes de cada receta cumplan con la restricción
    3. Si una receta tiene ingredientes que no son #{dietary}, NO la recomiendes
    4. Explicar por qué cada receta recomendada es apta para #{dietary}
    5. Si el usuario especificó ingredientes preferidos, prioriza recetas que los incluyan
    6. Cuando menciones ingredientes que tienen una URL en el CONTEXTO (marcados como [Ingrediente](http://localhost:4000/graph/xxx)), crea un enlace usando EXACTAMENTE esa URL

    REGLAS:
    - SOLO recomienda recetas del CONTEXTO que sean #{dietary}
    - Copia nombre EXACTO y URL EXACTA
    - Si no hay recetas aptas, sugiérelo honestamente
    - Indica si alguna receta puede adaptarse fácilmente
    - CRÍTICO: Para ingredientes con URL en el contexto, copia la URL EXACTA del formato [Ingrediente](http://localhost:4000/graph/xxx) - NO inventes IDs
    - Si un ingrediente NO tiene URL en el contexto, NO crees un enlace para él

    ===== CONTEXTO (Recetas disponibles) =====
    #{reference_material}
    ===== FIN DEL CONTEXTO =====

    PREGUNTA: "#{question}"

    Encuentra recetas #{dietary}#{meal_type_context} en el contexto y recomiéndalas.
    NO inventes URLs ni IDs - usa SOLO las URLs que aparecen explícitamente en el contexto.
    """
  end
end
