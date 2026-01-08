defmodule LidlChef.IntentClassifier do
  @moduledoc """
  LLM-based intent classification for recipe queries.

  Classifies user queries into specific intents to enable
  targeted prompts and optimized search strategies.
  """

  require Logger

  @type intent :: :ingredient_search | :meal_planning | :recipe_question | :dietary_filter | :general_search

  @intent_descriptions %{
    ingredient_search: "User has specific ingredients and wants recipes that use them",
    meal_planning: "User wants a meal plan (daily, weekly menu)",
    recipe_question: "User is asking about a specific recipe or cooking technique",
    dietary_filter: "User has dietary restrictions (vegan, gluten-free, etc.)",
    general_search: "General recipe search or browsing"
  }

  @classification_prompt """
  You are a recipe query classifier. Analyze the user's query and classify it into ONE of these intents:

  1. INGREDIENT_SEARCH - User mentions specific ingredients they have and wants recipes
     Examples: "Tengo pollo y arroz", "Que puedo hacer con lentejas?", "I have tomatoes and cheese"

  2. MEAL_PLANNING - User wants a meal plan (breakfast/lunch/dinner, daily menu, weekly menu)
     Examples: "Dame un menú semanal", "Plan de comidas para 7 días", "Menú diario"

  3. RECIPE_QUESTION - User asks about a specific recipe, technique, or cooking question
     Examples: "Como se hace la paella?", "Cuanto tiempo cocinar el pollo?", "Tips para cocinar arroz"

  4. DIETARY_FILTER - User mentions dietary restrictions prominently
     Examples: "Recetas veganas", "Sin gluten", "Bajo en calorías"

  5. GENERAL_SEARCH - General recipe browsing or unspecific requests
     Examples: "Dame una receta", "Recetas de cena", "Algo para cocinar"

  Also extract:
  - INGREDIENTS: List any specific ingredients mentioned (comma-separated)
  - MEAL_TYPE: breakfast, lunch, dinner, snack, or none
  - DIETARY: Any dietary restrictions mentioned
  - DAYS: Number of days if meal planning (1 for daily, 7 for weekly, etc.)

  Respond ONLY in this exact format (no extra text):
  INTENT: <intent_name>
  INGREDIENTS: <ingredient1, ingredient2, ...> or NONE
  MEAL_TYPE: <meal_type> or NONE
  DIETARY: <restriction> or NONE
  DAYS: <number> or NONE
  """

  @doc """
  Classifies a user query into an intent with extracted entities.

  Returns a map with:
  - :intent - The classified intent atom
  - :ingredients - List of extracted ingredients
  - :meal_type - Extracted meal type or nil
  - :dietary - Dietary restriction or nil
  - :days - Number of days for meal planning or nil
  - :confidence - Confidence level (:high, :medium, :low)
  """
  @spec classify(String.t()) :: {:ok, map()} | {:error, term()}
  def classify(query) do
    # First try fast rule-based classification for common patterns
    case fast_classify(query) do
      {:ok, result} when result.confidence == :high ->
        Logger.debug("Intent classified (fast): #{result.intent}")
        {:ok, result}

      _ ->
        # Fall back to LLM classification for ambiguous cases
        llm_classify(query)
    end
  end

  @doc """
  Fast rule-based classification for common patterns.
  Returns {:ok, result} with confidence level, or {:uncertain, partial_result}.
  """
  def fast_classify(query) do
    lower = String.downcase(query)

    result = %{
      intent: nil,
      ingredients: extract_ingredients(lower),
      meal_type: extract_meal_type(lower),
      dietary: extract_dietary(lower),
      days: extract_days(lower),
      confidence: :low
    }

    # Check for meal planning patterns (highest priority)
    cond do
      is_meal_planning?(lower) ->
        {:ok, %{result | intent: :meal_planning, confidence: :high}}

      # "Tengo X" or "con X e Y" patterns strongly indicate ingredient search
      has_ingredient_possession_pattern?(lower) and length(result.ingredients) > 0 ->
        {:ok, %{result | intent: :ingredient_search, confidence: :high}}

      # Direct ingredient query patterns
      has_ingredient_query_pattern?(lower) and length(result.ingredients) > 0 ->
        {:ok, %{result | intent: :ingredient_search, confidence: :high}}

      # Dietary filter is prominent
      result.dietary != nil and String.contains?(lower, ["recetas", "platos", "comida"]) ->
        {:ok, %{result | intent: :dietary_filter, confidence: :medium}}

      # Recipe question patterns
      is_recipe_question?(lower) ->
        {:ok, %{result | intent: :recipe_question, confidence: :medium}}

      # Has ingredients but no clear pattern - likely ingredient search
      length(result.ingredients) > 0 ->
        {:ok, %{result | intent: :ingredient_search, confidence: :medium}}

      # Default to general search
      true ->
        {:ok, %{result | intent: :general_search, confidence: :low}}
    end
  end

  defp is_meal_planning?(query) do
    String.contains?(query, ["menú", "menu", "semanal", "semana", "diario"]) or
    Regex.match?(~r/\d+\s*d[íi]as?/, query) or
    String.contains?(query, ["plan de comidas", "planificar comidas"])
  end

  defp has_ingredient_possession_pattern?(query) do
    # "Tengo X", "tenemos X", "hay X en casa", "por casa"
    Regex.match?(~r/\b(tengo|tenemos|hay|dispongo)\b.*\b(y|,|e)\b/i, query) or
    String.contains?(query, "por casa") or
    String.contains?(query, "en casa") or
    String.contains?(query, "en la nevera") or
    String.contains?(query, "en el frigo")
  end

  defp has_ingredient_query_pattern?(query) do
    # "con X e Y", "usando X", "que use X"
    Regex.match?(~r/\b(con|usando|que use|que lleve|con base de)\b/i, query) or
    Regex.match?(~r/(que|qué)\s+(puedo|podría|podemos)\s+(hacer|cocinar|preparar)/i, query) or
    Regex.match?(~r/(recetas?|platos?)\s+(con|de|usando)/i, query)
  end

  defp is_recipe_question?(query) do
    Regex.match?(~r/\b(como|cómo)\s+(se\s+)?(hace|prepara|cocina)/i, query) or
    Regex.match?(~r/\b(cuanto|cuánto)\s+tiempo/i, query) or
    Regex.match?(~r/\b(tips?|consejos?|trucos?)\s+(para|de)/i, query)
  end

  defp extract_ingredients(query) do
    # Common Spanish ingredients to detect
    common_ingredients = [
      "pollo", "arroz", "pasta", "macarrones", "espaguetis", "lentejas",
      "garbanzos", "judías", "alubias", "tomate", "cebolla", "ajo",
      "pimiento", "zanahoria", "patata", "huevo", "queso", "leche",
      "carne", "cerdo", "ternera", "pescado", "atún", "salmón",
      "verdura", "verduras", "calabacín", "berenjena", "espinacas",
      "champiñones", "setas", "pan", "harina", "aceite", "mantequilla",
      "tofu", "tempeh", "jamón", "bacon", "chorizo", "morcilla"
    ]

    # Find all ingredients mentioned in the query
    common_ingredients
    |> Enum.filter(fn ingredient -> String.contains?(query, ingredient) end)
  end

  defp extract_meal_type(query) do
    cond do
      String.contains?(query, ["desayuno", "breakfast"]) -> :breakfast
      String.contains?(query, ["almuerzo", "comida", "lunch"]) -> :lunch
      String.contains?(query, ["cena", "dinner"]) -> :dinner
      String.contains?(query, ["merienda", "snack"]) -> :snack
      true -> nil
    end
  end

  defp extract_dietary(query) do
    cond do
      String.contains?(query, ["vegano", "vegan"]) -> "vegano"
      String.contains?(query, ["vegetariano", "vegetarian"]) -> "vegetariano"
      String.contains?(query, ["sin gluten", "gluten-free", "celiaco"]) -> "sin gluten"
      String.contains?(query, ["bajo en calorías", "light", "ligero"]) -> "bajo en calorías"
      String.contains?(query, ["sin lactosa"]) -> "sin lactosa"
      String.contains?(query, ["keto", "cetogénica"]) -> "keto"
      true -> nil
    end
  end

  defp extract_days(query) do
    cond do
      String.contains?(query, ["semanal", "semana"]) -> 7
      String.contains?(query, "diario") -> 1
      true ->
        case Regex.run(~r/(\d+)\s*d[íi]as?/, query) do
          [_, days] -> String.to_integer(days)
          _ -> nil
        end
    end
  end

  # LLM-based classification for complex/ambiguous queries
  defp llm_classify(query) do
    prompt = """
    #{@classification_prompt}

    USER QUERY: "#{query}"
    """

    case LidlChef.LLM.complete(prompt, max_tokens: 150, temperature: 0.1) do
      {:ok, response} ->
        parse_classification_response(response, query)

      {:error, reason} ->
        Logger.warning("LLM classification failed: #{inspect(reason)}, falling back to rule-based")
        fast_classify(query)
    end
  end

  defp parse_classification_response(response, original_query) do
    lines = String.split(response, "\n", trim: true)

    parsed = Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = key |> String.trim() |> String.upcase()
          value = String.trim(value)
          Map.put(acc, key, value)
        _ ->
          acc
      end
    end)

    intent = case Map.get(parsed, "INTENT", "GENERAL_SEARCH") |> String.upcase() do
      "INGREDIENT_SEARCH" -> :ingredient_search
      "MEAL_PLANNING" -> :meal_planning
      "RECIPE_QUESTION" -> :recipe_question
      "DIETARY_FILTER" -> :dietary_filter
      _ -> :general_search
    end

    ingredients = case Map.get(parsed, "INGREDIENTS", "NONE") do
      "NONE" -> extract_ingredients(String.downcase(original_query))
      value -> String.split(value, ",") |> Enum.map(&String.trim/1)
    end

    meal_type = case Map.get(parsed, "MEAL_TYPE", "NONE") do
      "NONE" -> nil
      "breakfast" -> :breakfast
      "lunch" -> :lunch
      "dinner" -> :dinner
      "snack" -> :snack
      _ -> nil
    end

    dietary = case Map.get(parsed, "DIETARY", "NONE") do
      "NONE" -> nil
      value -> value
    end

    days = case Map.get(parsed, "DAYS", "NONE") do
      "NONE" -> nil
      value ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> nil
        end
    end

    {:ok, %{
      intent: intent,
      ingredients: ingredients,
      meal_type: meal_type,
      dietary: dietary,
      days: days,
      confidence: :high
    }}
  end

  @doc """
  Returns a description of the intent for debugging/logging.
  """
  def intent_description(intent) do
    Map.get(@intent_descriptions, intent, "Unknown intent")
  end
end
