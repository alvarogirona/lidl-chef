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

  Use the CONTEXT provided (recipe documents) to suggest meals.

  IMPORTANT RULES:
  1. For each recipe you recommend, you MUST include:
     - The exact recipe name as it appears in the context
     - The complete URL to the recipe (from the context)

  2. Format your recommendations like this:
     "I recommend trying **[Recipe Name]** ([URL]). This dish..."

  3. MISSING INGREDIENTS: Compare the user's available ingredients with the recipe's
     required ingredients. If the user is missing some ingredients, add a section:

     🛒 **Shopping List for [Recipe Name]:**
     - [ingredient 1]
     - [ingredient 2]

  4. If the user mentions dietary preferences (vegan, vegetarian, gluten-free, etc.),
     only recommend recipes that match those preferences.

  5. Always respond in the same language the user uses (Spanish for Spanish queries,
     English for English queries).

  6. Be friendly, encouraging, and provide helpful cooking tips when relevant.
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

    if use_simple do
      simple_ask(question, opts)
    else
      agentic_ask(question, opts)
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

    try do
      ctx =
        Agent.new(question, repo: Repo)
        |> Agent.expand()
        |> Agent.search(collection: Recipes.collection_name(), limit: limit, graph: false)
        |> Agent.rerank(threshold: 5)
        |> Agent.answer(
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

    CONTEXT (Recipe Documents):
    #{reference_material}

    USER QUESTION: "#{question}"

    Provide a helpful response using the recipes from the context. Remember to include recipe names and URLs in your recommendations.
    """
  end
end
