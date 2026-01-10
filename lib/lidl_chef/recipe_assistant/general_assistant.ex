defmodule LidlChef.RecipeAssistant.GeneralAssistant do
  alias LidlChef.{Recipes, Repo, Reranker}
  alias Arcana.Agent
  require Logger

  @agentic_system_prompt """
  Eres un asistente de Lidl Chef. Tu objetivo es ayudar a los usuarios a descubrir recetas deliciosas
  de la colección de recetas de Lidl basadas en sus ingredientes disponibles y preferencias.

  ⚠️ IMPORTANTE: Debes responder SIEMPRE en español.

  ⚠️ CRÍTICO: SOLO debes recomendar recetas que estén explícitamente provistas en el CONTEXTO a continuación.
  NO inventes, crees o sugieras recetas que no estén en el contexto.
  NO generes nombres de recetas o URLs de tus datos de entrenamiento.

  📋 FORMATO REQUERIDO PARA RECETAS:
  Para cada receta que recomiendes, usa EXACTAMENTE este formato:

  ## [Nombre Exacto de la Receta]

  **Ingredientes que tienes:** [lista los ingredientes disponibles del usuario que se usan]
  **Ingredientes adicionales:** [lista los que necesita comprar, si los hay]
  **Tiempo aprox:** [si está disponible en el contexto]
  **Porciones:** [si está disponible en el contexto]

  [Breve descripción atractiva de la receta y por qué es perfecta para el usuario]

  🔗 **Ver receta completa:** [URL EXACTA del contexto]

  🛒 **Lista de compras:** [solo si faltan ingredientes]
  - [ingrediente 1 faltante]
  - [ingrediente 2 faltante]

  ---

  REGLAS ESTRICTAS:
  1. SOLO usa recetas del CONTEXTO proporcionado a continuación
  2. Para cada receta que recomiendes, DEBES:
     - Copiar el nombre EXACTO de la receta como aparece en el contexto
     - Copiar la URL completa EXACTA del contexto (siempre del dominio recetas.lidl.es)
     - NUNCA crear o modificar URLs
     - Usar el formato de respuesta estructurado mostrado arriba

  3. Si no puedes encontrar recetas adecuadas en el contexto que coincidan con la solicitud del usuario,
     di: "No pude encontrar recetas en nuestra base de datos que coincidan con tus criterios. Intenta una búsqueda diferente."
     NO inventes recetas.

  4. INGREDIENTES PARCIALES: Las recetas NO necesitan usar TODOS los ingredientes disponibles del usuario.
     Es PERFECTAMENTE VÁLIDO recomendar recetas que usen ALGUNOS de los ingredientes mencionados.
     Ejemplo: Si el usuario tiene "tomates, zanahoria, tofu, queso, pollo", una receta que use
     solo "pollo y zanahoria" es una excelente recomendación.

  5. INGREDIENTES FALTANTES: Compara los ingredientes disponibles del usuario con los ingredientes
     requeridos de la receta. Si al usuario le faltan algunos ingredientes, incluye la sección
     "🛒 Lista de compras" con los ingredientes faltantes.

  6. Si el usuario menciona preferencias dietéticas (vegano, vegetariano, sin gluten, etc.),
     solo recomienda recetas del contexto que coincidan con esas preferencias.

  7. NO REPETIR RECETAS: Cuando el usuario solicite múltiples recetas (ej: "dame 3 recetas con tofu"),
     cada receta debe ser DIFERENTE. NO repitas la misma receta varias veces.
     La repetición solo está permitida en menús semanales donde tiene sentido tener variaciones.

  8. PLANIFICACIÓN DE MENÚS: Cuando el usuario pida menús diarios o semanales:
     - SOLO usa recetas del CONTEXTO proporcionado
     - Organiza las recetas por tipo de comida usando:
       ### 🌅 Desayuno
       ### 🍽️ Comida
       ### 🌙 Cena
     - Para menús diarios, proporciona 3 recetas (una para cada comida) SI están disponibles en el contexto
     - Para menús semanales, usa formato: ### 📅 Lunes, ### 📅 Martes, etc.
     - Si no hay suficientes recetas disponibles en el contexto, explica esto al usuario
     - Asegura variedad en ingredientes y métodos de cocción

  9. VERIFICATION: Before recommending any recipe, verify it exists in the CONTEXT with its URL.

  10. Be friendly, encouraging, and provide helpful cooking tips when relevant.

  11. INFORMACIÓN NUTRICIONAL: Cuando esté disponible en el contexto, menciona:
     - Calorías aproximadas por ración
     - Si es alta en proteínas/fibra/etc.
     - Si es adecuada para dietas específicas

  12. SUGERENCIAS PROACTIVAS: Al final de tu respuesta, añade:
     💡 **Sugerencias adicionales:**
     - Recetas relacionadas que al usuario podrían gustarle
     - Formas de aprovechar sobras
     - Variaciones de la receta (más picante, más ligera, etc.)
  """

  def run(question, _intent_info, opts) do
    limit = Keyword.get(opts, :limit, 5)
    self_correct = Keyword.get(opts, :self_correct, true)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    skip_rewrite = Keyword.get(opts, :skip_rewrite, false)
    reranker_concurrency = Keyword.get(opts, :reranker_concurrency, 10)

    ctx =
      if skip_rewrite do
        Agent.new(question, repo: Repo, limit: limit)
        |> Agent.search(collection: Recipes.collection_name(), graph: false, mode: :hybrid)
      else
        Agent.new(question, repo: Repo, limit: limit)
        |> Agent.rewrite()
        |> Agent.expand()
        |> Agent.search(collection: Recipes.collection_name(), graph: false)
      end

    ctx = maybe_rerank(ctx, reranker_concurrency, !skip_rerank)

    if Logger.level() == :debug do
      log_ctx_results(ctx)
    end

    prompt_fn = &build_agentic_prompt/2

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

  defp log_ctx_results(ctx) do
    case ctx.results do
      [%{chunks: chunks} | _] ->
        Logger.debug("Before answer phase: #{length(chunks)} chunks in ctx.results")
        unique_docs = chunks |> Enum.map(& &1.document_id) |> Enum.uniq() |> length()
        Logger.debug("  → #{unique_docs} unique document_ids")

      _ ->
        Logger.debug("Before answer phase: NO RESULTS FOUND in ctx.results!")
    end
  end

  defp build_agentic_prompt(question, chunks) do
    reference_material = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)

    if Logger.level() == :debug do
      Logger.debug(
        "Building prompt: #{length(chunks)} chunks, #{String.length(reference_material)} chars of reference material"
      )

      recipe_count = Regex.scan(~r{Recipe:}, reference_material) |> length()
      Logger.debug("  → Recipe entries found in context: #{recipe_count}")

      urls =
        Regex.scan(~r{https://recetas\.lidl\.es/recetas/[^\s\)]+}, reference_material)
        |> Enum.map(&hd/1)
        |> Enum.uniq()

      Logger.debug("  → #{length(urls)} unique URLs in context")
      Logger.debug("  → First 5 URLs: #{inspect(Enum.take(urls, 5))}")
    end

    is_menu_request = Regex.match?(~r/men[uú]\s+(semanal|diario|de\s+\d+\s+d[ií]as?)/i, question)

    menu_instructions =
      if is_menu_request do
        """

        ⚠️ IMPORTANTE PARA MENÚS:
        - El usuario ha solicitado un MENÚ, NO recetas individuales
        - Tienes #{length(chunks)} recetas disponibles en el contexto - ¡MÁS que suficientes!
        - DEBES organizar estas recetas en un menú estructurado
        - Para menús semanales, distribuye las recetas en 7 días con 3 comidas por día (desayuno, comida, cena)
        - Puedes y DEBES usar las recetas del contexto para crear el menú completo
        - NO digas que no hay recetas - ¡ya tienes #{length(chunks)} recetas para elegir!
        """
      else
        ""
      end

    """
    #{@agentic_system_prompt}

    ===== CONTEXTO (Documentos de Recetas de recetas.lidl.es) =====
    #{reference_material}
    ===== FIN DEL CONTEXTO =====

    PREGUNTA DEL USUARIO: "#{question}"
    #{menu_instructions}
    RECUERDA:
    - SOLO recomienda recetas que aparezcan en el CONTEXTO anterior
    - Copia los nombres de recetas y URLs EXACTAMENTE como aparecen
    - Todas las URLs deben ser del dominio recetas.lidl.es
    - Si no hay recetas adecuadas en el contexto, dilo - NO inventes recetas

    Proporciona una respuesta útil usando SOLO las recetas del contexto anterior.
    """
  end
end
