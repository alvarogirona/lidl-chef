defmodule LidlChef.RecipeAssistant.MealPlanner do
  alias LidlChef.{LLM, Recipes, Repo, Reranker}
  alias Arcana.Agent
  require Logger

  @meal_types [:breakfast, :lunch, :dinner]
  # How many recipes to fetch per query during search
  @recipes_per_query 10
  # Multiplier for final selection (2x the days needed)
  @selection_multiplier 3

  def run(question, intent_info, opts) do
    IO.inspect(opts, label: "MealPlanner opts")

    skip_rerank = false
    search_fn = Keyword.get(opts, :search_fn, &default_search/2)
    answer_fn = Keyword.get(opts, :answer_fn, fn _ctx, _answer_opts -> "" end)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)

    days = intent_info.days || 1
    dietary = intent_info.dietary

    meals_context =
      search_and_rerank_by_meal_type(
        question,
        days,
        dietary,
        search_fn,
        reranker_concurrency,
        !skip_rerank
      )

    prompt_fn = fn _question, _chunks ->
      build_meal_planning_prompt(question, meals_context, intent_info)
    end

    all_chunks = flatten_meals_context(meals_context)

    ctx =
      Agent.new(question, repo: Repo, limit: length(all_chunks))
      |> Map.put(:question, question)
      |> Map.put(:results, [
        %{
          question: question,
          collection: Recipes.collection_name(),
          chunks: all_chunks,
          iterations: 1
        }
      ])

    ctx
    |> answer_fn.(
      repo: Repo,
      prompt: prompt_fn,
      self_correct: false
    )
    |> handle_answer()
  end

  def run_stream(question, intent_info, on_chunk, opts) when is_function(on_chunk, 1) do
    IO.inspect(opts, label: "MealPlanner opts")

    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    search_fn = Keyword.get(opts, :search_fn, &default_search/2)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)

    days = intent_info.days || 1
    dietary = intent_info.dietary

    meals_context =
      search_and_rerank_by_meal_type(
        question,
        days,
        dietary,
        search_fn,
        reranker_concurrency,
        !skip_rerank
      )

    log_meals_context(meals_context)

    build_meal_planning_prompt(question, meals_context, intent_info)
    |> LLM.stream(on_chunk, opts)
  end

  defp search_and_rerank_by_meal_type(question, days, dietary, search_fn, concurrency, do_rerank) do
    target_per_meal = days * @selection_multiplier

    Logger.info(
      "[MealPlanner] Searching for #{days} days, target #{target_per_meal} recipes per meal type"
    )

    @meal_types
    |> Enum.map(fn meal_type ->
      {meal_type,
       search_and_rerank_meal(
         meal_type,
         question,
         days,
         dietary,
         target_per_meal,
         search_fn,
         concurrency,
         do_rerank
       )}
    end)
    |> Map.new()
  end

  defp search_and_rerank_meal(
         meal_type,
         question,
         _days,
         dietary,
         target_count,
         search_fn,
         concurrency,
         do_rerank
       ) do
    queries = build_meal_type_queries(meal_type, dietary)

    Logger.debug("[MealPlanner] #{meal_type}: Running #{length(queries)} queries")

    chunks =
      queries
      |> Enum.flat_map(fn query ->
        search_single(query, @recipes_per_query, search_fn)
      end)
      |> deduplicate_chunks()

    Logger.debug("[MealPlanner] #{meal_type}: Found #{length(chunks)} unique recipes")

    reranked_chunks =
      if do_rerank and length(chunks) > 0 do
        rerank_query = build_rerank_query(question, meal_type, dietary)
        rerank_chunks(chunks, rerank_query, concurrency)
      else
        Logger.debug("[MealPlanner] #{meal_type}: Skipping rerank (do_rerank=#{do_rerank})")
        chunks
      end

    final_chunks = Enum.take(reranked_chunks, target_count)

    Logger.info(
      "[MealPlanner] #{meal_type}: Selected #{length(final_chunks)} recipes (from #{length(chunks)} found)"
    )

    final_chunks
  end

  defp build_rerank_query(question, meal_type, dietary) do
    meal_context =
      case meal_type do
        :breakfast -> "para desayuno, receta ligera matutina"
        :lunch -> "para comida/almuerzo, plato principal del mediodía"
        :dinner -> "para cena, receta de noche"
      end

    dietary_context = if dietary, do: ", preferencia: #{dietary}", else: ""

    "#{question} - #{meal_context}#{dietary_context}"
  end

  defp rerank_chunks(chunks, query, concurrency) do
    {:ok, reranked} =
      Reranker.rerank(query, chunks,
        threshold: 2,
        concurrency: concurrency,
        base_url: "http://127.0.0.1:1234"
      )

    Logger.debug("[MealPlanner] Reranked #{length(chunks)} -> #{length(reranked)} chunks")
    reranked
  end

  defp build_meal_type_queries(meal_type, dietary) do
    base_queries = meal_type_base_queries(meal_type)
    ingredient_queries = meal_type_ingredient_queries(meal_type)

    all_queries = base_queries ++ ingredient_queries

    maybe_add_dietary_filter(all_queries, dietary)
  end

  defp meal_type_base_queries(:breakfast) do
    [
      "desayuno tostada smoothie zumo cereales",
      "desayuno ligero fruta yogur muesli",
      "desayuno energético avena granola",
      "desayuno rápido fácil mañana",
      "tortitas crepes gofres desayuno"
    ]
  end

  defp meal_type_base_queries(:lunch) do
    [
      "comida almuerzo ensalada plato principal",
      "arroz pasta legumbres comida",
      "pollo carne pescado principal almuerzo",
      "comida completa nutritiva",
      "plato único comida mediodía"
    ]
  end

  defp meal_type_base_queries(:dinner) do
    [
      "cena ligera sopa crema",
      "cena pescado verduras",
      "cena rápida fácil",
      "cena saludable nocturna",
      "cena ligera digestiva"
    ]
  end

  defp meal_type_ingredient_queries(:breakfast) do
    [
      "huevos tostada pan",
      "fruta yogur cereales",
      "café leche batido"
    ]
  end

  defp meal_type_ingredient_queries(:lunch) do
    [
      "verduras vegetales ensalada",
      "legumbres garbanzos lentejas",
      "pasta arroz cereales",
      "carne pollo ternera cerdo",
      "pescado marisco"
    ]
  end

  defp meal_type_ingredient_queries(:dinner) do
    [
      "verduras vapor plancha",
      "pescado ligero",
      "sopa puré crema",
      "ensalada proteína"
    ]
  end

  defp log_meals_context(meals_context) do
    Enum.each(@meal_types, fn meal_type ->
      chunks = Map.get(meals_context, meal_type, [])
      Logger.debug("[MealPlanner] Final #{meal_type}: #{length(chunks)} recipes")
    end)
  end

  defp flatten_meals_context(meals_context) do
    @meal_types
    |> Enum.flat_map(fn meal_type -> Map.get(meals_context, meal_type, []) end)
    |> deduplicate_chunks()
  end

  defp default_search(query, limit),
    do: Recipes.search(query, limit: limit, graph: false, mode: :hybrid)

  defp handle_answer(%{answer: answer}) when not is_nil(answer) do
    Logger.debug("[MealPlanner] Generated #{String.length(answer)} chars")
    {:ok, answer}
  end

  defp handle_answer(%{error: error}) do
    Logger.debug("[MealPlanner] NO ANSWER generated! Error: #{inspect(error)}")
    {:error, {:no_answer, "Agent did not generate an answer"}}
  end

  defp handle_answer(_) do
    Logger.debug("[MealPlanner] NO ANSWER generated!")
    {:error, {:no_answer, "Agent did not generate an answer"}}
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

  defp build_meal_planning_prompt(question, meals_context, intent_info) do
    days = intent_info.days || 1

    dietary_note =
      case intent_info.dietary do
        nil -> ""
        dietary -> "\n⚠️ El usuario requiere comidas #{dietary}."
      end

    breakfast_recipes = Map.get(meals_context, :breakfast, [])
    lunch_recipes = Map.get(meals_context, :lunch, [])
    dinner_recipes = Map.get(meals_context, :dinner, [])

    breakfast_text = format_recipes_section(breakfast_recipes, "Desayuno")
    lunch_text = format_recipes_section(lunch_recipes, "Comida/Almuerzo")
    dinner_text = format_recipes_section(dinner_recipes, "Cena")

    total_recipes = length(breakfast_recipes) + length(lunch_recipes) + length(dinner_recipes)

    Logger.debug(
      "[MealPlanner] Building prompt: #{days} days, #{length(breakfast_recipes)} breakfasts, #{length(lunch_recipes)} lunches, #{length(dinner_recipes)} dinners"
    )

    """
    Eres un asistente de Lidl Chef especializado en planificación de menús.

    ⚠️ RESPONDE SIEMPRE EN ESPAÑOL.
    #{dietary_note}

    El usuario quiere un menú para #{days} día(s).
    Tienes #{total_recipes} recetas disponibles organizadas por tipo de comida.

    INSTRUCCIONES PARA EL MENÚ:
    1. Organiza las recetas por día y tipo de comida (Desayuno, Comida, Cena)
    2. SOLO usa recetas de la sección correspondiente:
       - Para desayunos: usa SOLO recetas de "RECETAS PARA DESAYUNO"
       - Para comidas: usa SOLO recetas de "RECETAS PARA COMIDA/ALMUERZO"
       - Para cenas: usa SOLO recetas de "RECETAS PARA CENA"
    3. Asegura variedad: no repitas el mismo tipo de proteína dos días seguidos
    4. Incluye recetas ligeras para cenas y más contundentes para comidas
    5. Para cada receta, incluye nombre EXACTO y URL EXACTA del contexto
    6. Si el usuario te solicita 2 platos en la comida o cena, incluye dos recetas en cada una de esas comidas.

    FORMATO DE RESPUESTA:
    ## Día 1 (Lunes)
    ### 🌅 **Desayuno**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible)

    **Lista de ingredientes** (si está disponible)
    ### 🍽️ **Comida**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible)

    **Lista de ingredientes** (si está disponible)
    ### 🌙 **Cena**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible)

    **Lista de ingredientes** (si está disponible)
    (Repetir para cada día)

    REGLAS:
    - SOLO usa recetas del CONTEXTO de la sección apropiada
    - NO inventes recetas ni URLs
    - Tienes #{length(breakfast_recipes)} desayunos, #{length(lunch_recipes)} comidas y #{length(dinner_recipes)} cenas disponibles - ¡ÚSALAS!

    ===== RECETAS PARA DESAYUNO (#{length(breakfast_recipes)} disponibles) =====
    #{breakfast_text}

    ===== RECETAS PARA COMIDA/ALMUERZO (#{length(lunch_recipes)} disponibles) =====
    #{lunch_text}

    ===== RECETAS PARA CENA (#{length(dinner_recipes)} disponibles) =====
    #{dinner_text}

    ===== FIN DEL CONTEXTO =====

    PREGUNTA: "#{question}"

    Crea un menú variado y equilibrado usando las recetas del contexto correspondiente a cada comida.
    """
  end

  defp format_recipes_section([], section_name) do
    "No hay recetas disponibles para #{section_name}"
  end

  defp format_recipes_section(chunks, _section_name) do
    Enum.map_join(chunks, "\n\n---\n\n", & &1.text)
  end
end
