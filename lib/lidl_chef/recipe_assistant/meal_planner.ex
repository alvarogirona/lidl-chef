defmodule LidlChef.RecipeAssistant.MealPlanner do
  alias LidlChef.{LLM, Recipes, Repo, Reranker}
  alias Arcana.Agent
  require Logger

  def run(question, intent_info, opts) do
    IO.inspect(opts, label: "MealPlanner opts")
    target_limit = 50

    skip_rerank = Keyword.get(opts, :skip_rerank, true)

    search_fn = Keyword.get(opts, :search_fn, &default_search/2)
    answer_fn = Keyword.get(opts, :answer_fn, &default_answer/2)

        prompt_fn = fn question, chunks ->
      build_meal_planning_prompt(question, chunks, intent_info)
    end

    Agent.new(question, repo: Repo, limit: target_limit)
    |> Map.put(:question, question)
    |> multi_search_for_menus(question, target_limit, search_fn)
    |> maybe_rerank(Keyword.get(opts, :reranker_concurrency, 10), !skip_rerank)
    |> log_ctx_results()
    |> answer_fn.(
      repo: Repo,
      prompt: prompt_fn,
      self_correct: false
    )
    |> handle_answer()
  end

  def run_stream(question, intent_info, on_chunk, opts) when is_function(on_chunk, 1) do
    IO.inspect(opts, label: "MealPlanner opts")
    target_limit = 50
    skip_rerank = Keyword.get(opts, :skip_rerank, true)
    search_fn = Keyword.get(opts, :search_fn, &default_search/2)

    Agent.new(question, repo: Repo, limit: target_limit)
    |> multi_search_for_menus(question, target_limit, search_fn)
    |> maybe_rerank(Keyword.get(opts, :reranker_concurrency, 10), !skip_rerank)
    |> log_ctx_results()
    |> extract_chunks()
    |> build_meal_planning_prompt(question, intent_info)
    |> LLM.stream(on_chunk, opts)
  end

  defp maybe_rerank(ctx, _concurrency, false), do: ctx

  defp maybe_rerank(ctx, reranker_concurrency, true) do
    Agent.rerank(ctx,
      reranker: Reranker,
      threshold: 2,
      concurrency: reranker_concurrency,
      base_url: "http://127.0.0.1:1234"
    )
  end

  defp log_ctx_results(%{results: [%{chunks: chunks} | _]} = ctx) do
    Logger.debug("After multi_search_for_menus: ctx.results has #{length(chunks)} chunks")
    ctx
  end

  defp log_ctx_results(ctx) do
    Logger.debug("After multi_search_for_menus: ctx.results has 0 chunks")
    ctx
  end

  defp extract_chunks(%{results: [%{chunks: chunks} | _]}), do: chunks
  defp extract_chunks(_), do: []

  defp default_search(query, limit),
    do: Recipes.search(query, limit: limit, graph: false, mode: :hybrid)

  # Multi-search strategy for menu queries to gather diverse recipes
  defp multi_search_for_menus(ctx, question, target_limit, search_fn) do
    lower_question = String.downcase(question)
    dietary_filter = extract_dietary_filter(lower_question)
    search_queries = build_menu_search_queries(lower_question, dietary_filter)

    Logger.debug("Multi-search: Running #{length(search_queries)} queries...")

    limit_per_query = 10

    Logger.debug(
      "Fetching #{limit_per_query} chunks per query (#{length(search_queries)} queries total)"
    )

    all_chunks =
      search_queries
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {query, idx} ->
        chunks = search_single(query, limit_per_query, search_fn)

        Logger.debug(
          "  #{idx}/#{length(search_queries)}: \"#{query}\" -> #{length(chunks)}"
        )

        chunks
      end)
      |> deduplicate_chunks()
      |> Enum.take(target_limit)

    Logger.debug(
      "Multi-search: Total #{length(all_chunks)} unique chunks (target #{target_limit})"
    )

    %{
      ctx
      | results: [
          %{
            question: ctx.question,
            collection: Recipes.collection_name(),
            chunks: all_chunks,
            iterations: 1
          }
        ]
    }
  end

  defp extract_dietary_filter(question) do
    filters = [
      {["vegano"], "vegano"},
      {["vegetariano"], "vegetariano"},
      {["sin gluten", "celiaco"], "sin gluten"},
      {["bajo en calorías", "light", "ligero"], "light bajo calorías"}
    ]

    Enum.find_value(filters, fn {keywords, filter} ->
      if String.contains?(question, keywords), do: filter
    end)
  end

  defp build_menu_search_queries(question, dietary_filter) do
    base_queries = [
      "desayuno tostada smoothie zumo cereales",
      "desayuno ligero fruta yogur muesli",
      "comida almuerzo ensalada plato principal",
      "arroz pasta legumbres comida",
      "pollo carne pescado principal",
      "cena ligera sopa crema",
      "cena pescado verduras",
      "cena rápida fácil",
      "postre dulce fruta",
      "snack merienda tentempié"
    ]

    ingredient_queries = [
      "verduras vegetales",
      "legumbres garbanzos lentejas",
      "pasta arroz cereales",
      "carne pollo ternera cerdo",
      "pescado marisco"
    ]

    queries = maybe_add_dietary_filter(base_queries, dietary_filter)

    original_terms =
      question
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split()
      |> Enum.reject(&(String.length(&1) < 3))
      |> Enum.take(5)
      |> Enum.join(" ")

    all_queries = queries ++ ingredient_queries

    case original_terms do
      "" -> all_queries
      terms -> [terms | all_queries]
    end
  end

  defp maybe_add_dietary_filter(queries, nil), do: queries

  defp maybe_add_dietary_filter(queries, filter) do
    Enum.map(queries, &"#{&1} #{filter}")
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

  defp build_meal_planning_prompt(chunks, question, intent_info) do
    reference_material = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)
    days = intent_info.days || 1

    dietary_note =
      case intent_info.dietary do
        nil -> ""
        dietary -> "\n⚠️ El usuario requiere comidas #{dietary}."
      end

    Logger.debug("Building meal planning prompt: #{length(chunks)} chunks, #{days} days")

    """
    Eres un asistente de Lidl Chef especializado en planificación de menús.

    ⚠️ RESPONDE SIEMPRE EN ESPAÑOL.
    #{dietary_note}

    El usuario quiere un menú para #{days} día(s).
    Tienes #{length(chunks)} recetas disponibles en el contexto para crear el menú.

    INSTRUCCIONES PARA EL MENÚ:
    1. Organiza las recetas por día y tipo de comida (Desayuno, Comida, Cena)
    2. Asegura variedad: no repitas el mismo tipo de proteína dos días seguidos
    3. Incluye recetas ligeras para cenas y más contundentes para comidas
    4. Para cada receta, incluye nombre EXACTO y URL EXACTA del contexto
    5. Si el usuario te solicita 2 platos en la comida o cena, incluye dos recetas en cada una de esas comidas.

    FORMATO DE RESPUESTA:
    ## Día 1 (Lunes)
    ### 🌅 **Desayuno**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible) \n\n
    **Lista de ingredientes** (si está disponible)
    ### 🍽️ **Comida**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible) \n\n
    **Lista de ingredientes** (si está disponible)
    ### 🌙 **Cena**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible) \n\n
    **Lista de ingredientes** (si está disponible)
    (Repetir para cada día)

    REGLAS:
    - SOLO usa recetas del CONTEXTO
    - NO inventes recetas ni URLs
    - Tienes #{length(chunks)} recetas disponibles - ¡ÚSALAS!

    ===== CONTEXTO (#{length(chunks)} Recetas disponibles) =====
    #{reference_material}
    ===== FIN DEL CONTEXTO =====

    PREGUNTA: "#{question}"

    Crea un menú variado y equilibrado usando las recetas del contexto.
    """
  end
end
