defmodule LidlChef.IntentClassifier do
  @moduledoc """
  LLM-based intent classification for recipe queries.

  Classifies user queries into specific intents to enable
  targeted prompts and optimized search strategies.
  """

  require Logger

  @type intent ::
          :ingredient_search
          | :meal_planning
          | :recipe_question
          | :dietary_filter
          | :general_search

  @intent_descriptions %{
    ingredient_search: "User has specific ingredients and wants recipes that use them",
    meal_planning: "User wants a meal plan (daily, weekly menu)",
    recipe_question: "User is asking about a specific recipe or cooking technique",
    dietary_filter: "User has dietary restrictions (vegan, gluten-free, etc.)",
    general_search: "General recipe search or browsing"
  }

  @classification_prompt """
  Eres un clasificador de intenciones de recetas. Analiza la consulta del usuario y clasifícala en UNA de estas intenciones:

  1. INGREDIENT_SEARCH - El usuario menciona ingredientes específicos que tiene y quiere recetas.
     Si el usuario menciona ingredientes, significa que quiere encontrar recetas que los usen.
     Ejemplos: "Tengo pollo y arroz", "¿Qué puedo hacer con lentejas?", "I have tomatoes and cheese"

  2. MEAL_PLANNING - El usuario quiere un plan de comidas (desayuno/almuerzo/cena, menú diario, menú semanal)
     Ejemplos: "Dame un menú semanal", "Plan de comidas para 7 días", "Menú diario"

  3. RECIPE_QUESTION - El usuario pregunta sobre una receta específica, técnica o duda de cocina
     Ejemplos: "¿Cómo se hace la paella?", "¿Cuánto tiempo cocinar el pollo?", "Consejos para cocinar arroz"

  4. DIETARY_FILTER - El usuario menciona restricciones dietéticas de forma prominente
     Ejemplos: "Recetas veganas", "Sin gluten", "Bajo en calorías"

  5. GENERAL_SEARCH - Navegación general de recetas o solicitudes no específicas
     Ejemplos: "Dame una receta", "Recetas de cena", "Algo para cocinar"
  También extrae:
  - INGREDIENTS: Lista de ingredientes específicos mencionados (separados por comas)
  - FOOD_TYPE: desayuno, almuerzo, cena, merienda, o ninguno
  - DIETARY: Cualquier restricción dietética mencionada
  - DAYS: número de días si es planificación de comidas (1 para diario, 7 para semanal, etc.)
  - ATTRIBUTES: Cualquier otro atributo relevante (por ejemplo, tipo de cocina, tiempo de cocción, alto en proteínas, etc.)

  Responde SOLO en este formato exacto (sin texto adicional):
  INTENT: <intent_name>
  INGREDIENTS: <ingredient1, ingredient2, ...> or NONE (in original language of the query)
  FOOD_TYPE: <meal_type> or NONE
  DIETARY: <restriction> or NONE
  DAYS: <number> or NONE
  ATTRIBUTES: <attribute1, attribute2, ...> or NONE
  """

  @doc """
  Classifies a user query into an intent with extracted entities.

  Returns a map with:
  - :intent - The classified intent atom
  - :ingredients - List of extracted ingredients
  - :meal_type - Extracted meal type or nil
  - :dietary - Dietary restriction or nil
  - :days - Number of days for meal planning or nil
  """
  @spec classify(String.t()) :: {:ok, map()} | {:error, term()}
  def classify(query) do
    case llm_classify(query) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        Logger.warning("LLM classification failed: #{inspect(reason)}, using safe fallback")
        {:error, reason}
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
        {:error, reason}
    end
  end

  defp parse_classification_response(response, _original_query) do
    lines = String.split(response, "\n", trim: true)

    parsed =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            key = key |> String.trim() |> String.upcase()
            value = String.trim(value)
            Map.put(acc, key, value)

          _ ->
            acc
        end
      end)

    IO.inspect(parsed, label: "Parsed Classification Response")

    intent =
      case Map.get(parsed, "INTENT", "GENERAL_SEARCH") |> String.upcase() do
        "INGREDIENT_SEARCH" -> :ingredient_search
        "MEAL_PLANNING" -> :meal_planning
        "RECIPE_QUESTION" -> :recipe_question
        "DIETARY_FILTER" -> :dietary_filter
        _ -> :general_search
      end

    ingredients =
      case Map.get(parsed, "INGREDIENTS", "NONE") do
        "NONE" -> []
        value -> String.split(value, ",") |> Enum.map(&String.trim/1)
      end

    meal_type =
      case Map.get(parsed, "MEAL_TYPE", "NONE") do
        "NONE" -> nil
        "breakfast" -> :breakfast
        "lunch" -> :lunch
        "dinner" -> :dinner
        "snack" -> :snack
        _ -> nil
      end

    dietary =
      case Map.get(parsed, "DIETARY", "NONE") do
        "NONE" -> nil
        value -> value
      end

    attributes =
      case Map.get(parsed, "ATTRIBUTES", "NONE") do
        "NONE" -> []
        value -> String.split(value, ",") |> Enum.map(&String.trim/1)
      end

    days =
      case Map.get(parsed, "DAYS", "NONE") do
        "NONE" ->
          nil

        value ->
          case Integer.parse(value) do
            {n, _} -> n
            :error -> nil
          end
      end

    {:ok,
     %{
       intent: intent,
       ingredients: ingredients,
       meal_type: meal_type,
       dietary: dietary,
       days: days,
       attributes: attributes
     }}
  end

  @doc """
  Returns a description of the intent for debugging/logging.
  """
  def intent_description(intent) do
    Map.get(@intent_descriptions, intent, "Unknown intent")
  end
end
