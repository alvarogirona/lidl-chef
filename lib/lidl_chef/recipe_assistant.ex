defmodule LidlChef.RecipeAssistant do
  @moduledoc """
  AI-powered recipe assistant using RAG (Retrieval Augmented Generation).

  Provides conversational interface for recipe recommendations based on
  available ingredients, dietary preferences, and cooking constraints.
  """

  alias LidlChef.{Recipes, Repo}
  alias Arcana.Agent
  require Logger

  @system_prompt """
  You are a helpful cooking assistant for Lidl recipes. Your role is to help users find
  recipes based on the ingredients they have available.

  When recommending recipes:
  1. Focus on recipes that use the ingredients the user mentioned
  2. Suggest alternatives if exact matches aren't found
  3. Provide helpful cooking tips when relevant
  4. Be friendly and encouraging
  5. If nutritional information is available, mention it when relevant
  6. Always respond in the same language the user uses

  Format your responses clearly with recipe names, ingredients needed, and any
  important notes about preparation.
  """

  @agentic_system_prompt """
  Eres un asistente de Lidl Chef. Tu objetivo es ayudar a los usuarios a descubrir recetas deliciosas
  de la colección de recetas de Lidl basadas en sus ingredientes disponibles y preferencias.

  ⚠️ IMPORTANTE: Debes responder SIEMPRE en español.

  ⚠️ CRÍTICO: SOLO debes recomendar recetas que estén explícitamente provistas en el CONTEXTO a continuación.
  NO inventes, crees o sugieras recetas que no estén en el contexto.
  NO generes nombres de recetas o URLs de tus datos de entrenamiento.

  REGLAS ESTRICTAS:
  1. SOLO usa recetas del CONTEXTO proporcionado a continuación
  2. Para cada receta que recomiendes, DEBES:
     - Copiar el nombre EXACTO de la receta como aparece en el contexto
     - Copiar la URL completa EXACTA del contexto (siempre del dominio recetas.lidl.es)
     - NUNCA crear o modificar URLs

  3. Formatea tus recomendaciones así:
     "Te recomiendo probar **[Nombre de la Receta]** ([URL]). Este plato..."

  4. Si no puedes encontrar recetas adecuadas en el contexto que coincidan con la solicitud del usuario,
     di: "No pude encontrar recetas en nuestra base de datos que coincidan con tus criterios. Intenta una búsqueda diferente."
     NO inventes recetas.

  5. INGREDIENTES PARCIALES: Las recetas NO necesitan usar TODOS los ingredientes disponibles del usuario.
     Es PERFECTAMENTE VÁLIDO recomendar recetas que usen ALGUNOS de los ingredientes mencionados.
     Ejemplo: Si el usuario tiene "tomates, zanahoria, tofu, queso, pollo", una receta que use
     solo "pollo y zanahoria" es una excelente recomendación.

  6. INGREDIENTES FALTANTES: Compara los ingredientes disponibles del usuario con los ingredientes
     requeridos de la receta. Si al usuario le faltan algunos ingredientes, añade una sección:

     🛒 **Lista de Compras para [Nombre de la Receta]:**
     - [ingrediente 1]
     - [ingrediente 2]

  7. Si el usuario menciona preferencias dietéticas (vegano, vegetariano, sin gluten, etc.),
     solo recomienda recetas del contexto que coincidan con esas preferencias.

  8. NO REPETIR RECETAS: Cuando el usuario solicite múltiples recetas (ej: "dame 3 recetas con tofu"),
     cada receta debe ser DIFERENTE. NO repitas la misma receta varias veces.
     La repetición solo está permitida en menús semanales donde tiene sentido tener variaciones.

  9. PLANIFICACIÓN DE MENÚS: Cuando el usuario pida menús diarios o semanales:
     - SOLO usa recetas del CONTEXTO proporcionado
     - Organiza las recetas por tipo de comida (desayuno, comida, cena)
     - Para menús diarios, proporciona 3 recetas (una para cada comida) SI están disponibles en el contexto
     - Para menús semanales, proporciona recetas variadas en diferentes días SI están disponibles en el contexto
     - Si no hay suficientes recetas disponibles en el contexto, explica esto al usuario
     - Asegura variedad en ingredientes y métodos de cocción
     - Formatea los menús claramente con encabezados como "## Lunes" o "## Desayuno"

  10. Always respond in the same language the user uses (Spanish for Spanish queries,
     English for English queries).

  9. Be friendly, encouraging, and provide helpful cooking tips when relevant.

  11. VERIFICATION: Before recommending any recipe, verify it exists in the CONTEXT with its URL.
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
    use_simple = Keyword.get(opts, :simple, false)

    # Auto-detect menu queries and increase limit if not explicitly set
    opts = adjust_limit_for_query(question, opts)

    # if use_simple do
    #  simple_ask(question, opts)
    # else
      agentic_ask(question, opts)
    # end
  end

  # Detect menu queries and adjust limit accordingly
  defp adjust_limit_for_query(question, opts) do
    lower_question = String.downcase(question)
    is_menu_query = String.contains?(lower_question, ["menú", "menu", "semanal", "semana", "diario", "día"])

    # Adjust limit if not explicitly set
    opts = if Keyword.has_key?(opts, :limit) do
      opts
    else
      cond do
        # Weekly menu queries need more recipes (7 days * 3 meals = 21)
        String.contains?(lower_question, ["semanal", "semana"]) ->
          Keyword.put(opts, :limit, 30)

        # Daily menu queries need recipes for 3 meals
        String.contains?(lower_question, ["diario", "día", "desayuno", "comida", "cena"]) ->
          Keyword.put(opts, :limit, 15)

        # Default
        true ->
          Keyword.put(opts, :limit, 5)
      end
    end

    # For menu queries: enable multi-search, disable reranking and self-correction
    if is_menu_query do
      opts
      |> Keyword.put_new(:multi_search, true)
      |> Keyword.put_new(:skip_rerank, true)
      |> Keyword.put_new(:self_correct, false)
    else
      opts
    end
  end

  defp simple_ask(question, opts) do
    limit = Keyword.get(opts, :limit, 5)

    # Use Agent pipeline without expansion and self-correction for simpler/faster responses
    try do
      ctx =
        Agent.new(question, repo: Repo)
        |> Agent.search(collection: Recipes.collection_name(), limit: limit, graph: false)
        |> Agent.answer(
          repo: Repo,
          prompt: &build_simple_prompt/2,
          self_correct: false
        )

      case ctx.answer do
        nil -> {:error, {:no_answer, "Agent did not generate an answer"}}
        answer -> {:ok, answer}
      end
    rescue
      e -> {:error, {:agent_error, Exception.message(e)}}
    end
  end

  defp agentic_ask(question, opts) do
    limit = Keyword.get(opts, :limit, 5)
    self_correct = Keyword.get(opts, :self_correct, true)
    skip_rerank = Keyword.get(opts, :skip_rerank, false)
    use_multi_search = Keyword.get(opts, :multi_search, false)

    try do
      ctx = Agent.new(question, repo: Repo)
        |> Agent.expand()

      # For menu queries, use multi-search to gather more diverse recipes
      ctx = if use_multi_search do
        multi_search_for_menus(ctx, question, limit)
      else
        Agent.search(ctx, collection: Recipes.collection_name(), limit: limit, graph: false)
      end

      # Skip reranking for menu queries - it processes each chunk individually with LLM
      # which filters out recipes before the LLM can see them all together
      ctx = if skip_rerank do
        ctx
      else
        # Lower threshold (3 instead of 5) to accept partial ingredient matches
        # A recipe that uses SOME of the user's ingredients is still valuable
        Agent.rerank(ctx, threshold: 3)
      end

      ctx = Agent.answer(ctx,
        repo: Repo,
        prompt: &build_agentic_prompt/2,
        self_correct: self_correct
      )

      case ctx.answer do
        nil -> {:error, {:no_answer, "Agent did not generate an answer"}}
        answer -> {:ok, answer}
      end
    rescue
      e -> {:error, {:agent_error, Exception.message(e)}}
    end
  end

  # Multi-search strategy for menu queries to gather diverse recipes
  defp multi_search_for_menus(ctx, question, target_limit) do
    lower_question = String.downcase(question)

    # Extract dietary restrictions from the question
    dietary_filter = extract_dietary_filter(lower_question)

    # Define search queries for different meal types and variety
    search_queries = build_menu_search_queries(lower_question, dietary_filter)

    # Perform multiple searches and collect unique chunks
    limit_per_query = max(div(target_limit, length(search_queries)) + 2, 5)

    all_chunks =
      search_queries
      |> Enum.flat_map(fn query ->
        search_single(query, limit_per_query)
      end)
      |> deduplicate_chunks()
      |> Enum.take(target_limit * 2)  # Take more than needed to ensure variety

    Logger.debug("Multi-search collected #{length(all_chunks)} unique chunks for menu query")

    # Update context with combined results - matching the exact structure Arcana expects
    %{ctx |
      results: [%{
        question: ctx.question,
        collection: Recipes.collection_name(),
        chunks: all_chunks,
        iterations: 1
      }]
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

    # Add dietary filter to each query if present
    queries = if dietary_filter do
      Enum.map(base_queries, fn q -> "#{q} #{dietary_filter}" end)
    else
      base_queries
    end

    # Also add the original question context
    original_terms = question
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split()
      |> Enum.reject(&(String.length(&1) < 3))
      |> Enum.take(5)
      |> Enum.join(" ")

    if original_terms != "" do
      [original_terms | queries]
    else
      queries
    end
  end

  defp search_single(query, limit) do
    case Recipes.search(query, limit: limit, graph: false, mode: :hybrid) do
      {:ok, chunks} -> chunks
      _ -> []
    end
  end

  defp deduplicate_chunks(chunks) do
    chunks
    |> Enum.uniq_by(fn chunk ->
      # Deduplicate by document_id or by extracting title from text
      chunk.document_id || extract_title_from_chunk(chunk.text)
    end)
  end

  defp extract_title_from_chunk(text) do
    case Regex.run(~r/Recipe:\s*(.+?)(?:\n|$)/i, text) do
      [_, title] -> String.trim(title)
      _ -> text  # Fallback to full text if no title found
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

  defp build_simple_prompt(question, chunks) do
    reference_material = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)

    """
    #{@system_prompt}

    Reference material:
    #{reference_material}

    Question: "#{question}"

    Answer the question directly and naturally. Use the reference material to inform your answer.
    """
  end

  defp build_agentic_prompt(question, chunks) do
    reference_material = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)

    """
    #{@agentic_system_prompt}

    ===== CONTEXTO (Documentos de Recetas de recetas.lidl.es) =====
    #{reference_material}
    ===== FIN DEL CONTEXTO =====

    PREGUNTA DEL USUARIO: "#{question}"

    RECUERDA:
    - SOLO recomienda recetas que aparezcan en el CONTEXTO anterior
    - Copia los nombres de recetas y URLs EXACTAMENTE como aparecen
    - Todas las URLs deben ser del dominio recetas.lidl.es
    - Si no hay recetas adecuadas en el contexto, dilo - NO inventes recetas

    Proporciona una respuesta útil usando SOLO las recetas del contexto anterior.
    """
  end
end
