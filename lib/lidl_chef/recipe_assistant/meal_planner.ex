defmodule LidlChef.RecipeAssistant.MealPlanner do
  alias LidlChef.{Recipes, Repo, Reranker}
  alias Arcana.Agent
  require Logger

  def run(question, intent_info, opts) do
    IO.inspect(opts, label: "MealPlanner opts")
    # For meal planning, we typically want a lot of candidate recipes to ensure variety.
    target_limit = Keyword.get(opts, :limit, 50)

    # Reranking is often skipped for meal planning to keep diversity and volume, or maybe done?
    # Original code had: :skip_rerank, true for :meal_planning
    skip_rerank = Keyword.get(opts, :skip_rerank, true)

    # Allow test-time injection (no network / deterministic).
    search_fn = Keyword.get(opts, :search_fn, &default_search/2)
    answer_fn = Keyword.get(opts, :answer_fn, &default_answer/2)

    # We use multi_search by default for meal planning
    ctx = Agent.new(question, repo: Repo, limit: target_limit)
    ctx = %{ctx | question: question}

    ctx = multi_search_for_menus(ctx, question, target_limit, search_fn)

    # Rerank if not skipped (default is skipped)
    ctx = maybe_rerank(ctx, Keyword.get(opts, :reranker_concurrency, 10), !skip_rerank)

    if Logger.level() == :debug do
      log_ctx_results(ctx)
    end

    prompt_fn = fn question, chunks ->
      build_meal_planning_prompt(question, chunks, intent_info)
    end

    ctx =
      answer_fn.(ctx,
        repo: Repo,
        prompt: prompt_fn,
        self_correct: false
      )

    handle_answer(ctx)
  end

  defp handle_answer(ctx) do
    if ctx.answer do
      Logger.debug("After answer phase: Generated #{String.length(ctx.answer)} chars")
      {:ok, ctx.answer}
    else
      Logger.debug("After answer phase: NO ANSWER generated! Error: #{inspect(ctx.error)}")
      {:error, {:no_answer, "Agent did not generate an answer"}}
    end
  end

  defp maybe_rerank(ctx, _, false), do: ctx

  defp maybe_rerank(ctx, reranker_concurrency, true),
    do:
      Agent.rerank(ctx,
        reranker: Reranker,
        threshold: 2,
        concurrency: reranker_concurrency,
        base_url: "http://127.0.0.1:1234"
      )

  defp log_ctx_results(ctx) do
    result_chunks =
      case ctx.results do
        [%{chunks: chunks} | _] -> length(chunks)
        _ -> 0
      end

    Logger.debug("After multi_search_for_menus: ctx.results has #{result_chunks} chunks")
  end

  defp default_answer(ctx, opts), do: Agent.answer(ctx, opts)

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
          "  #{idx}/#{length(search_queries)}: \"#{String.slice(query, 0, 35)}\" -> #{length(chunks)}"
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
    cond do
      String.contains?(question, ["vegano"]) -> "vegano"
      String.contains?(question, ["vegetariano"]) -> "vegetariano"
      String.contains?(question, ["sin gluten", "celiaco"]) -> "sin gluten"
      String.contains?(question, ["bajo en calorías", "light", "ligero"]) -> "light bajo calorías"
      true -> nil
    end
  end

  defp build_menu_search_queries(question, dietary_filter) do
    base_queries = [
      # Breakfast queries
      "desayuno tostada smoothie zumo cereales",
      "desayuno ligero fruta yogur muesli",
      # Lunch queries
      "comida almuerzo ensalada plato principal",
      "arroz pasta legumbres comida",
      "pollo carne pescado principal",
      # Dinner queries
      "cena ligera sopa crema",
      "cena pescado verduras",
      "cena rápida fácil",
      # Variety
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

    queries =
      if dietary_filter do
        Enum.map(base_queries, fn q -> "#{q} #{dietary_filter}" end)
      else
        base_queries
      end

    original_terms =
      question
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split()
      |> Enum.reject(&(String.length(&1) < 3))
      |> Enum.take(5)
      |> Enum.join(" ")

    all_queries = queries ++ ingredient_queries

    if original_terms != "" do
      [original_terms | all_queries]
    else
      all_queries
    end
  end

  defp search_single(query, limit, search_fn) do
    cache_key = {:recipe_search, query, limit}
    ttl = :timer.hours(2)

    case Cachex.fetch(:recipe_search_cache, cache_key, fn _key ->
           case search_fn.(query, limit) do
             {:ok, chunks} -> {:commit, chunks, ttl: ttl}
             _ -> {:ignore, []}
           end
         end) do
      {:ok, chunks} ->
        chunks

      {:commit, chunks} ->
        chunks

      {:error, _} ->
        # If cache isn't available for any reason, still try searching.
        case search_fn.(query, limit) do
          {:ok, chunks} -> chunks
          _ -> []
        end

      _ ->
        []
    end
  end

  defp deduplicate_chunks(chunks) do
    chunks
    |> Enum.uniq_by(fn chunk ->
      chunk.document_id || extract_title_from_chunk(chunk.text)
    end)
  end

  defp extract_title_from_chunk(text) do
    case Regex.run(~r/Recipe:\s*(.+?)(?:\n|$)/i, text) do
      [_, title] -> String.trim(title)
      _ -> text
    end
  end

  defp build_meal_planning_prompt(question, chunks, intent_info) do
    reference_material = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)
    days = intent_info.days || 1
    dietary = intent_info.dietary

    dietary_note = if dietary, do: "\n⚠️ El usuario requiere comidas #{dietary}.", else: ""

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

    FORMATO DE RESPUESTA:
    ## Día 1 (Lunes)
    - 🌅 **Desayuno**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible)
    **Lista de ingredientes** (si está disponible)
    - 🍽️ **Comida**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible)
    **Lista de ingredientes** (si está disponible)
    - 🌙 **Cena**: [Nombre de Receta](URL) - breve descripción
    **Información nutricional** (si está disponible)
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
