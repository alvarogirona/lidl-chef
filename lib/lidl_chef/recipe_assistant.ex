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
  You are a Lidl Chef assistant. Your goal is to help users discover delicious recipes
  from the Lidl recipe collection based on their available ingredients and preferences.

  ⚠️ CRITICAL: You MUST ONLY recommend recipes that are explicitly provided in the CONTEXT below.
  DO NOT invent, make up, or suggest any recipes that are not in the context.
  DO NOT generate recipe names or URLs from your training data.

  STRICT RULES:
  1. ONLY use recipes from the CONTEXT provided below
  2. For each recipe you recommend, you MUST:
     - Copy the EXACT recipe name as it appears in the context
     - Copy the EXACT complete URL from the context (always from recetas.lidl.es domain)
     - NEVER create or modify URLs

  3. Format your recommendations like this:
     "I recommend trying **[Recipe Name]** ([URL]). This dish..."

  4. If you cannot find suitable recipes in the context that match the user's request,
     say: "I couldn't find recipes in our database that match your criteria. Try a different search."
     DO NOT make up recipes.

  5. MISSING INGREDIENTS: Compare the user's available ingredients with the recipe's
     required ingredients. If the user is missing some ingredients, add a section:

     🛒 **Shopping List for [Recipe Name]:**
     - [ingredient 1]
     - [ingredient 2]

  6. If the user mentions dietary preferences (vegan, vegetarian, gluten-free, etc.),
     only recommend recipes from the context that match those preferences.

  7. MENU PLANNING: When the user asks for daily or weekly menus:
     - ONLY use recipes from the provided CONTEXT
     - Organize recipes by meal type (breakfast/desayuno, lunch/comida, dinner/cena)
     - For daily menus, provide 3 recipes (one for each meal) IF available in context
     - For weekly menus, provide varied recipes across different days IF available in context
     - If not enough recipes are available in the context, explain this to the user
     - Ensure variety in ingredients and cooking methods
     - Format menus clearly with headers like "## Monday / Lunes" or "## Breakfast / Desayuno"

  8. Always respond in the same language the user uses (Spanish for Spanish queries,
     English for English queries).

  9. Be friendly, encouraging, and provide helpful cooking tips when relevant.

  10. VERIFICATION: Before recommending any recipe, verify it exists in the CONTEXT with its URL.
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
    is_menu_query = String.contains?(lower_question, ["menú", "menu", "semanal", "weekly", "semana", "week", "diario", "daily", "día", "day"])

    # Adjust limit if not explicitly set
    opts = if Keyword.has_key?(opts, :limit) do
      opts
    else
      cond do
        # Weekly menu queries need more recipes (7 days * 3 meals = 21)
        String.contains?(lower_question, ["semanal", "weekly", "semana", "week"]) ->
          Keyword.put(opts, :limit, 30)

        # Daily menu queries need recipes for 3 meals
        String.contains?(lower_question, ["diario", "daily", "día", "day", "desayuno", "comida", "cena", "breakfast", "lunch", "dinner"]) ->
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
        Agent.rerank(ctx, threshold: 5)
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
      String.contains?(question, ["vegano", "vegan"]) -> "vegano vegan"
      String.contains?(question, ["vegetariano", "vegetarian"]) -> "vegetariano vegetarian"
      String.contains?(question, ["sin gluten", "gluten-free", "gluten free"]) -> "sin gluten"
      String.contains?(question, ["bajo en calorías", "low calorie", "light"]) -> "light bajo calorías"
      true -> nil
    end
  end

  defp build_menu_search_queries(question, dietary_filter) do
    base_queries = [
      # Breakfast queries
      "desayuno breakfast tostada smoothie zumo cereales",
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

    ===== CONTEXT (Recipe Documents from recetas.lidl.es) =====
    #{reference_material}
    ===== END OF CONTEXT =====

    USER QUESTION: "#{question}"

    REMEMBER:
    - ONLY recommend recipes that appear in the CONTEXT above
    - Copy recipe names and URLs EXACTLY as they appear
    - All URLs must be from recetas.lidl.es domain
    - If no suitable recipes are in the context, say so - DO NOT invent recipes

    Provide a helpful response using ONLY the recipes from the context above.
    """
  end
end
