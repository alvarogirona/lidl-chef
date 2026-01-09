defmodule LidlChef.RecipeAssistant do
  @moduledoc """
  AI-powered recipe assistant using RAG (Retrieval Augmented Generation).

  Provides conversational interface for recipe recommendations based on
  available ingredients, dietary preferences, and cooking constraints.
  """

  alias LidlChef.{IntentClassifier, Recipes, Repo}
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

  @doc """
  Ask a question about recipes and get an AI-powered response.

  Uses the Arcana Agent pipeline with query expansion, search, reranking,
  and self-correcting answers for high-quality responses.

  ## Options

    * `:simple` - Use simple RAG instead of agentic pipeline (default: false)
    * `:limit` - Number of recipes to retrieve (default: 5)
    * `:self_correct` - Enable answer self-correction (default: true)

  ## Examples

      iex> LidlChef.RecipeAssistant.ask("What can I make with chicken and rice?")
      {:ok, "Based on the recipes available, here are some options..."}

  """
  @spec ask(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ask(question, opts \\ []) do
    {:ok, intent_info} = IntentClassifier.classify(question)

    Logger.debug(
      "Intent classified: #{intent_info.intent} (confidence: #{intent_info.confidence})"
    )

    Logger.debug("  Ingredients: #{inspect(intent_info.ingredients)}")
    Logger.debug("  Dietary: #{inspect(intent_info.dietary)}")

    opts = configure_opts_for_intent(intent_info, opts)

    agentic_ask(question, intent_info, opts)
  end

  defp configure_opts_for_intent(intent_info, opts) do
    opts =
      case intent_info.intent do
        :meal_planning ->
          days = intent_info.days || 1
          limit = if days >= 7, do: 50, else: 15

          opts
          |> Keyword.put_new(:limit, limit)
          |> Keyword.put_new(:multi_search, true)
          |> Keyword.put_new(:skip_rerank, true)
          |> Keyword.put_new(:self_correct, false)

        :ingredient_search ->
          # For ingredient searches, use hybrid search directly without rewrite/expand
          # which can mangle the ingredient list
          opts
          |> Keyword.put_new(:limit, 10)
          |> Keyword.put_new(:skip_rewrite, true)
          |> Keyword.put_new(:skip_rerank, false)
          |> Keyword.put_new(:self_correct, true)

        :dietary_filter ->
          opts
          |> Keyword.put_new(:limit, 10)
          |> Keyword.put_new(:skip_rewrite, true)
          |> Keyword.put_new(:skip_rerank, false)
          |> Keyword.put_new(:self_correct, true)

        :recipe_question ->
          opts
          |> Keyword.put_new(:limit, 5)
          |> Keyword.put_new(:skip_rewrite, false)
          |> Keyword.put_new(:skip_rerank, false)
          |> Keyword.put_new(:self_correct, true)

        _ ->
          opts
          |> Keyword.put_new(:limit, 5)
          |> Keyword.put_new(:skip_rewrite, false)
          |> Keyword.put_new(:skip_rerank, false)
          |> Keyword.put_new(:self_correct, true)
      end

    # Store intent info in opts for later use in prompt building
    Keyword.put(opts, :intent_info, intent_info)
  end

  defp agentic_ask(question, intent_info, opts) do
    limit = Keyword.get(opts, :limit, 5)
    self_correct = Keyword.get(opts, :self_correct, true)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    skip_rewrite = Keyword.get(opts, :skip_rewrite, false)
    use_multi_search = Keyword.get(opts, :multi_search, false)

    Logger.debug(
      "agentic_ask: limit=#{limit}, skip_rewrite=#{skip_rewrite}, skip_rerank=#{skip_rerank}, multi_search=#{use_multi_search}"
    )

    Logger.debug("Original question: #{question}")

    try do
      ctx =
        cond do
          use_multi_search ->
            ctx = Agent.new(question, repo: Repo, limit: 50)
            ctx = %{ctx | question: question}
            multi_search_for_menus(ctx, question, 50)

          # Ingredient search: use ingredients directly for better search
          intent_info.intent == :ingredient_search and length(intent_info.ingredients) > 0 ->
            search_query = build_ingredient_search_query(intent_info)
            Logger.debug("Built ingredient search query: #{search_query}")

            ctx = Agent.new(question, repo: Repo, limit: limit)
            # Replace question with optimized search query but keep original for prompt
            search_with_query(ctx, search_query, question, limit)

          skip_rewrite ->
            Agent.new(question, repo: Repo, limit: limit)
            |> Agent.search(collection: Recipes.collection_name(), graph: false, mode: :hybrid)

          true ->
            Agent.new(question, repo: Repo, limit: limit)
            |> Agent.rewrite()
            |> Agent.expand()
            |> Agent.search(collection: Recipes.collection_name(), graph: false)
        end

      # Skip reranking for menu queries - it processes each chunk individually with LLM
      # which filters out recipes before the LLM can see them all together
      ctx =
        if skip_rerank do
          ctx
        else
          Agent.rerank(ctx, reranker: LidlChef.Reranker, threshold: 2)
        end

      if Logger.level() == :debug do
        case ctx.results do
          [%{chunks: chunks} | _] ->
            Logger.debug("Before answer phase: #{length(chunks)} chunks in ctx.results")
            unique_docs = chunks |> Enum.map(& &1.document_id) |> Enum.uniq() |> length()
            Logger.debug("  → #{unique_docs} unique document_ids")

          _ ->
            Logger.debug("Before answer phase: NO RESULTS FOUND in ctx.results!")
        end
      end

      prompt_fn = build_prompt_for_intent(intent_info)

      ctx =
        Agent.answer(ctx,
          repo: Repo,
          prompt: prompt_fn,
          self_correct: self_correct
        )

      if Logger.level() == :debug do
        if ctx.answer do
          Logger.debug("After answer phase: Generated #{String.length(ctx.answer)} chars")
        else
          Logger.debug("After answer phase: NO ANSWER generated! Error: #{inspect(ctx.error)}")
        end
      end

      case ctx.answer do
        nil -> {:error, {:no_answer, "Agent did not generate an answer"}}
        answer -> {:ok, answer}
      end
    rescue
      e -> {:error, {:agent_error, Exception.message(e)}}
    end
  end

  # Build optimized search query from extracted ingredients
  defp build_ingredient_search_query(intent_info) do
    ingredients = intent_info.ingredients
    dietary = intent_info.dietary
    meal_type = intent_info.meal_type
    base_query = Enum.join(ingredients, " ")
    # Add dietary filter if present
    base_query = if dietary, do: "#{base_query} #{dietary}", else: base_query

    # Add meal type context if present
    case meal_type do
      :breakfast -> "#{base_query} desayuno"
      :lunch -> "#{base_query} comida almuerzo"
      :dinner -> "#{base_query} cena"
      :snack -> "#{base_query} merienda snack"
      _ -> base_query
    end
  end

  # Search with an optimized query but keep original question for context
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

  # Build prompt function based on intent
  defp build_prompt_for_intent(intent_info) do
    case intent_info.intent do
      :ingredient_search ->
        fn question, chunks -> build_ingredient_prompt(question, chunks, intent_info) end

      :meal_planning ->
        fn question, chunks -> build_meal_planning_prompt(question, chunks, intent_info) end

      :dietary_filter ->
        fn question, chunks -> build_dietary_prompt(question, chunks, intent_info) end

      _ ->
        &build_agentic_prompt/2
    end
  end

  # Multi-search strategy for menu queries to gather diverse recipes
  defp multi_search_for_menus(ctx, question, target_limit) do
    lower_question = String.downcase(question)
    dietary_filter = extract_dietary_filter(lower_question)
    search_queries = build_menu_search_queries(lower_question, dietary_filter)

    Logger.debug("Multi-search: Running #{length(search_queries)} queries...")

    limit_per_query = max(div(target_limit, length(search_queries)), 5)

    Logger.debug(
      "Fetching #{limit_per_query} chunks per query (#{length(search_queries)} queries total)"
    )

    all_chunks =
      search_queries
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {query, idx} ->
        chunks = search_single(query, limit_per_query)

        Logger.debug(
          "  #{idx}/#{length(search_queries)}: \"#{String.slice(query, 0, 35)}\" -> #{length(chunks)}"
        )

        chunks
      end)
      |> deduplicate_chunks()
      # Take more than target to ensure variety after deduplication
      |> Enum.take(target_limit * 2)

    Logger.debug(
      "Multi-search: Total #{length(all_chunks)} unique chunks (target #{target_limit})"
    )

    # Debug: Log a sample of chunk texts to verify they contain recipe data
    if Logger.level() == :debug and length(all_chunks) > 0 do
      Logger.debug("Sample chunk preview: #{String.slice(hd(all_chunks).text, 0, 150)}...")
    end

    # Update context with combined results - matching the exact structure Arcana expects
    updated_ctx = %{
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

    if Logger.level() == :debug do
      result_chunks =
        case updated_ctx.results do
          [%{chunks: chunks} | _] -> length(chunks)
          _ -> 0
        end

      Logger.debug("After multi_search_for_menus: ctx.results has #{result_chunks} chunks")
    end

    updated_ctx
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

    time_queries = [
      "rápido fácil 30 minutos",
      "lento guiso cocción"
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

    all_queries = queries ++ time_queries ++ ingredient_queries

    if original_terms != "" do
      [original_terms | all_queries]
    else
      all_queries
    end
  end

  defp search_single(query, limit) do
    cache_key = {:recipe_search, query, limit}
    ttl = :timer.hours(2)

    case Cachex.fetch(:recipe_search_cache, cache_key,
           fn _key ->
             case Recipes.search(query, limit: limit, graph: false, mode: :hybrid) do
               {:ok, chunks} -> {:commit, chunks, ttl: ttl}
               _ -> {:ignore, []}
             end
           end
         ) do
      {:ok, chunks} -> chunks
      {:commit, chunks} -> chunks
      _ -> []
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

  @doc """
  Get recipe recommendations based on a list of available ingredients.

  This is the primary function for the ingredient-based recipe finder.

  ## Examples

      iex> LidlChef.RecipeAssistant.recommend_from_ingredients(["pollo", "arroz", "cebolla"])
      {:ok, "Con esos ingredientes puedes preparar..."}

  """
  @spec recommend_from_ingredients(list(String.t()), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def recommend_from_ingredients(ingredients, opts \\ []) when is_list(ingredients) do
    question = """
    I have these ingredients available: #{Enum.join(ingredients, ", ")}.
    What recipes can I make with them? Please suggest the best options
    and let me know if I need any additional ingredients.
    """

    ask(question, opts)
  end

  @doc """
  Get recipe recommendations with dietary restrictions.

  ## Examples

      iex> LidlChef.RecipeAssistant.recommend_with_diet(["chicken", "vegetables"], "gluten-free")
      {:ok, "Here are some gluten-free recipes..."}

  """
  @spec recommend_with_diet(list(String.t()), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def recommend_with_diet(ingredients, dietary_restriction, opts \\ []) do
    question = """
    I have these ingredients: #{Enum.join(ingredients, ", ")}.
    I need recipes that are #{dietary_restriction}.
    What can I make?
    """

    ask(question, opts)
  end

  @doc """
  Ask a follow-up question about a specific recipe.

  ## Examples

      iex> LidlChef.RecipeAssistant.ask_about_recipe("Patatas con bacalao", "How long does it take?")
      {:ok, "The preparation time for Patatas con bacalao is..."}

  """
  @spec ask_about_recipe(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def ask_about_recipe(recipe_name, question, opts \\ []) do
    full_question = """
    About the recipe "#{recipe_name}": #{question}
    """

    ask(full_question, opts)
  end

  @doc """
  Suggest recipes based on a meal type and available ingredients.

  ## Examples

      iex> LidlChef.RecipeAssistant.suggest_for_meal("dinner", ["beef", "potatoes"])
      {:ok, "For dinner with beef and potatoes, you could make..."}

  """
  @spec suggest_for_meal(String.t(), list(String.t()), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def suggest_for_meal(meal_type, ingredients, opts \\ []) do
    question = """
    I'm looking for #{meal_type} ideas. I have: #{Enum.join(ingredients, ", ")}.
    What recipes would you recommend?
    """

    ask(question, opts)
  end

  @doc """
  Get a quick recipe summary without full RAG pipeline.

  Useful for autocomplete or preview functionality.
  """
  @spec quick_search(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def quick_search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    Recipes.search(query, limit: limit, graph: false, mode: :hybrid)
  end

  # Helper functions

  # Prompt optimized for ingredient-based searches
  defp build_ingredient_prompt(question, chunks, intent_info) do
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
    - Formatea así: "**[Nombre de Receta]** ([URL]) - Usa: [ingredientes que tiene el usuario]"

    ===== CONTEXTO (Recetas disponibles) =====
    #{reference_material}
    ===== FIN DEL CONTEXTO =====

    PREGUNTA DEL USUARIO: "#{question}"

    Busca recetas en el contexto que usen: #{ingredients}

    Si encuentras recetas relevantes, recomiéndalas con entusiasmo.
    Si no encuentras ninguna receta que use estos ingredientes, sugiere qué otros ingredientes podrían complementarlos.
    """
  end

  # Prompt optimized for meal planning
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
    - 🍽️ **Comida**: [Nombre de Receta](URL) - breve descripción
    - 🌙 **Cena**: [Nombre de Receta](URL) - breve descripción

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

  # Prompt optimized for dietary restrictions
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
