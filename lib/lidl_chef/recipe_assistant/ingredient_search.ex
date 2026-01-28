defmodule LidlChef.RecipeAssistant.IngredientSearch do
  alias LidlChef.{LLM, Recipes, Repo}
  alias Arcana.Agent
  require Logger

  def run(question, intent_info, opts) when length(intent_info.ingredients) > 0 do
    limit = Keyword.get(opts, :limit, 10)
    self_correct = Keyword.get(opts, :self_correct, true)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)

    search_query = build_ingredient_search_query(intent_info)
    Logger.debug("Built ingredient search query: #{search_query}")

    Agent.new(question, repo: Repo, limit: limit)
    |> search_with_query(search_query, question, limit)
    |> maybe_rerank(reranker_concurrency, !skip_rerank)
    |> log_ctx_results()
    |> Agent.answer(
      repo: Repo,
      prompt: fn question, chunks -> build_ingredient_prompt(question, chunks, intent_info) end,
      self_correct: self_correct
    )
    |> handle_answer()
  end

  def run_stream(question, intent_info, on_chunk, opts)
      when length(intent_info.ingredients) > 0 and is_function(on_chunk, 1) do
    limit = Keyword.get(opts, :limit, 10)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)

    search_query = build_ingredient_search_query(intent_info)
    Logger.debug("Built ingredient search query: #{search_query}")

    Agent.new(question, repo: Repo, limit: limit)
    |> search_with_query(search_query, question, limit)
    |> maybe_rerank(reranker_concurrency, !skip_rerank)
    |> log_ctx_results()
    |> extract_chunks()
    |> build_ingredient_prompt(question, intent_info)
    |> LLM.stream(on_chunk, opts)
  end

  def run(question, intent_info, opts) do
    limit = Keyword.get(opts, :limit, 10)
    self_correct = Keyword.get(opts, :self_correct, true)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)

    ctx =
      Agent.new(question, repo: Repo, limit: limit)
      |> Agent.search(collection: Recipes.collection_name(), graph: false, mode: :hybrid)
      |> maybe_rerank(reranker_concurrency, !skip_rerank)
      |> Agent.answer(
        repo: Repo,
        prompt: fn question, chunks -> build_ingredient_prompt(question, chunks, intent_info) end,
        self_correct: self_correct
      )
      |> handle_answer()
  end

  def run_stream(question, intent_info, on_chunk, opts) when is_function(on_chunk, 1) do
    limit = Keyword.get(opts, :limit, 10)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)

    ctx =
      Agent.new(question, repo: Repo, limit: limit)
      |> Agent.search(collection: Recipes.collection_name(), graph: false, mode: :hybrid)
      |> maybe_rerank(reranker_concurrency, !skip_rerank)
      |> extract_chunks()
      |> build_ingredient_prompt(question, intent_info)
      |> LLM.stream(on_chunk, opts)
  end

  defp handle_answer(%{answer: answer}) when not is_nil(answer) do
    Logger.debug("After answer phase: Generated #{String.length(answer)} chars")
    {:ok, answer}
  end

  defp handle_answer(%{error: error}) do
    Logger.debug("After answer phase: NO ANSWER generated! Error: #{inspect(error)}")
    {:error, {:no_answer, "Agent did not generate an answer"}}
  end

  defp maybe_rerank(ctx, _, false), do: ctx

  defp maybe_rerank(ctx, reranker_concurrency, true),
    do:
      Agent.rerank(ctx,
        reranker: LidlChef.Reranker,
        threshold: 2,
        concurrency: reranker_concurrency,
        base_url: "http://127.0.0.1:1234"
      )

  defp log_ctx_results(ctx) do
    case ctx.results do
      [%{chunks: chunks} | _] ->
        Logger.debug("Before answer phase: #{length(chunks)} chunks in ctx.results")
        unique_docs = chunks |> Enum.map(& &1.document_id) |> Enum.uniq() |> length()
        Logger.debug("  → #{unique_docs} unique document_ids")

      _ ->
        Logger.debug("Before answer phase: NO RESULTS FOUND in ctx.results!")
    end

    ctx
  end

  defp extract_chunks(%{results: [%{chunks: chunks} | _]}), do: chunks
  defp extract_chunks(_), do: []

  defp build_ingredient_search_query(intent_info) do
    ingredients = intent_info.ingredients
    dietary = intent_info.dietary
    meal_type = intent_info.meal_type
    base_query = Enum.join(ingredients, " ")

    base_query
    |> add_dietary_to_query(dietary)
    |> add_meal_type_to_query(meal_type)
  end

  defp add_dietary_to_query(base_query, dietary) when is_binary(dietary) do
    "#{base_query} #{dietary}"
  end

  defp add_dietary_to_query(base_query, _dietary), do: base_query

  defp add_meal_type_to_query(base_query, :breakfast), do: "#{base_query} desayuno"
  defp add_meal_type_to_query(base_query, :lunch), do: "#{base_query} comida almuerzo"
  defp add_meal_type_to_query(base_query, :dinner), do: "#{base_query} cena"
  defp add_meal_type_to_query(base_query, :snack), do: "#{base_query} merienda snack"
  defp add_meal_type_to_query(base_query, _), do: base_query

  defp search_with_query(ctx, search_query, original_question, limit) do
    case Recipes.search(search_query, limit: limit, graph: false, mode: :hybrid) do
      {:ok, [_ | _] = chunks} ->
        Logger.debug("Ingredient search found #{length(chunks)} chunks")

        %{
          ctx
          | question: original_question,
            results: [
              %{
                question: original_question,
                collection: Recipes.collection_name(),
                chunks: chunks,
                iterations: 1
              }
            ]
        }

      _ ->
        Logger.debug("Ingredient search found no results, trying standard search")

        ctx
        |> Agent.search(collection: Recipes.collection_name(), graph: false, mode: :hybrid)
    end
  end

  defp build_ingredient_prompt(chunks, question, intent_info) do
    reference_material = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)
    ingredients = Enum.join(intent_info.ingredients, ", ")

    Logger.debug(
      "Building ingredient prompt: #{length(chunks)} chunks, ingredients: #{ingredients}"
    )

    """
    Eres un asistente de Lidl Chef especializado en encontrar recetas basadas en ingredientes.

    ⚠️ RESPONDE SIEMPRE EN ESPAÑOL.

    El usuario tiene estos ingredientes disponibles: #{ingredients}

    Tu tarea es:
    1. Buscar en el CONTEXTO recetas que usen ALGUNOS de estos ingredientes
    2. Las recetas NO necesitan usar TODOS los ingredientes - con usar UNO o MÁS es suficiente
    3. Priorizar recetas que usen más ingredientes del usuario
    4. Para cada receta recomendada, indica qué ingredientes del usuario se usan
    5. Si faltan ingredientes para completar la receta, muestra una lista de compras

    REGLAS ESTRICTAS:
    - SOLO recomienda recetas del CONTEXTO - NO inventes recetas
    - Copia el nombre EXACTO y la URL EXACTA de cada receta
    - Si una receta usa al menos 1 ingrediente del usuario, es válida

    FORMATO REQUERIDO PARA CADA RECETA RECOMENDADA:
    ## [Nombre Exacto de la Receta] SIN LA URL QUE VA DESPUÉS
    - **Ingredientes que tienes:** [lista los ingredientes disponibles del usuario que se usan]
    - **Ingredientes adicionales:** [lista los que necesita comprar, si los hay]
    - **Tiempo aprox:** [si está disponible en el contexto]
    - **Porciones:** [si está disponible en el contexto]
    - **Informacion nutricional:** [si está disponible en el contexto]
    - [Breve descripción atractiva de la receta y por qué es perfecta para el usuario]
    - 🛒 **Lista de compras:** [solo si faltan ingredientes]
    🔗 **Ver receta completa:** [URL EXACTA del contexto

    ===== CONTEXTO (Recetas disponibles) =====
    #{reference_material}
    ===== FIN DEL CONTEXTO =====

    PREGUNTA DEL USUARIO: "#{question}"

    Busca recetas en el contexto que usen: #{ingredients}

    Si encuentras recetas relevantes, recomiéndalas con entusiasmo.
    Si no encuentras ninguna receta que use estos ingredientes, sugiere qué otros ingredientes podrían complementarlos.
    """
  end
end
