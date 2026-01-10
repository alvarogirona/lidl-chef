defmodule LidlChef.RecipeAssistant.DietarySearch do
  alias LidlChef.{Recipes, Repo, Reranker}
  alias Arcana.Agent
  require Logger

  def run(question, intent_info, opts) do
    limit = Keyword.get(opts, :limit, 10)
    self_correct = Keyword.get(opts, :self_correct, true)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)

    # For dietary search, skip rewrite to preserve specific dietary terms
    # Using hybrid search directly
    ctx =
      Agent.new(question, repo: Repo, limit: limit)
      |> Agent.search(collection: Recipes.collection_name(), graph: false, mode: :hybrid)

    ctx = maybe_rerank(ctx, reranker_concurrency, !skip_rerank)

    prompt_fn = fn question, chunks -> build_dietary_prompt(question, chunks, intent_info) end

    ctx =
      Agent.answer(ctx,
        repo: Repo,
        prompt: prompt_fn,
        self_correct: self_correct
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

  defp build_dietary_prompt(question, chunks, intent_info) do
    reference_material = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)
    dietary = intent_info.dietary || "especial"

    Logger.debug("Building dietary prompt: #{length(chunks)} chunks, dietary: #{dietary}")

    """
    Eres un asistente de Lidl Chef especializado en alimentación #{dietary}.

    ⚠️ RESPONDE SIEMPRE EN ESPAÑOL.

    El usuario busca recetas que sean #{dietary}.

    Tu tarea es:
    1. Revisar el CONTEXTO y encontrar recetas aptas para dieta #{dietary}
    2. Verificar que los ingredientes de cada receta cumplan con la restricción
    3. Si una receta tiene ingredientes que no son #{dietary}, NO la recomiendes
    4. Explicar por qué cada receta recomendada es apta para #{dietary}

    REGLAS:
    - SOLO recomienda recetas del CONTEXTO que sean #{dietary}
    - Copia nombre EXACTO y URL EXACTA
    - Si no hay recetas aptas, sugiérelo honestamente
    - Indica si alguna receta puede adaptarse fácilmente

    ===== CONTEXTO (Recetas disponibles) =====
    #{reference_material}
    ===== FIN DEL CONTEXTO =====

    PREGUNTA: "#{question}"

    Encuentra recetas #{dietary} en el contexto y recomiéndalas.
    """
  end
end
