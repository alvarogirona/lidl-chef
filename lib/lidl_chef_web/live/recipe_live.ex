defmodule LidlChefWeb.RecipeLive do
  use LidlChefWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:loading, false)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    if String.trim(query) != "" do
      send(self(), {:perform_search, query})

      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:loading, true)
       |> assign(:error, nil)}
    else
      {:noreply,
       socket
       |> assign(:query, query)
       |> assign(:results, [])
       |> assign(:loading, false)}
    end
  end

  @impl true
  def handle_event("ingredient_search", %{"ingredients" => ingredients}, socket) do
    ingredient_list =
      ingredients
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 != ""))

    if length(ingredient_list) > 0 do
      send(self(), {:perform_ingredient_search, ingredient_list})

      {:noreply,
       socket
       |> assign(:loading, true)
       |> assign(:error, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:perform_search, query}, socket) do
    try do
      {:ok, results} = LidlChef.Recipes.search(query, graph: false, limit: 10)

      {:noreply,
       socket
       |> assign(:results, results)
       |> assign(:loading, false)}
    rescue
      error ->
        {:noreply,
         socket
         |> assign(:results, [])
         |> assign(:loading, false)
         |> assign(:error, "Search failed: #{inspect(error)}")}
    end
  end

  @impl true
  def handle_info({:perform_ingredient_search, ingredients}, socket) do
    try do
      {:ok, results} = LidlChef.Recipes.find_by_ingredients(ingredients, graph: false, limit: 10)

      {:noreply,
       socket
       |> assign(:results, results)
       |> assign(:loading, false)}
    rescue
      error ->
        {:noreply,
         socket
         |> assign(:results, [])
         |> assign(:loading, false)
         |> assign(:error, "Ingredient search failed: #{inspect(error)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="max-w-6xl mx-auto p-6">
        <div class="text-center mb-8">
          <h1 class="text-4xl font-bold text-gray-900 mb-2">🛒 Lidl Chef</h1>
          <p class="text-xl text-gray-600">AI-Powered Recipe Discovery System</p>
          <p class="text-sm text-gray-500 mt-2">
            Search through 1,500+ Lidl recipes using AI embeddings
          </p>
          <div class="mt-4">
            <.link
              navigate="/chat"
              class="inline-flex items-center gap-2 bg-green-600 hover:bg-green-700 text-white px-6 py-3 rounded-lg font-medium transition-colors"
            >
              👨‍🍳 Chat with AI Chef
            </.link>
          </div>
        </div>
        
    <!-- Search Form -->
        <div class="bg-white rounded-lg shadow-lg p-6 mb-6">
          <.form :let={f} for={%{}} as={:search} phx-submit="search" id="search-form" class="mb-4">
            <div class="flex gap-4">
              <.input
                field={f[:query]}
                type="text"
                placeholder="Search for recipes... (e.g., 'pasta with vegetables', 'chicken dinner')"
                value={@query}
                class="flex-1"
              />
              <button
                type="submit"
                class="bg-blue-600 hover:bg-blue-700 text-white px-6 py-3 rounded-lg font-medium transition-colors"
                disabled={@loading}
              >
                <%= if @loading do %>
                  🔍 Searching...
                <% else %>
                  🔍 Search
                <% end %>
              </button>
            </div>
          </.form>
          
    <!-- Ingredient Search -->
          <div class="border-t pt-4">
            <h3 class="text-lg font-medium mb-2">Search by Ingredients</h3>
            <div class="flex gap-4">
              <input
                type="text"
                id="ingredients-input"
                placeholder="Enter ingredients separated by commas (e.g., chicken, tomato, onion)"
                class="flex-1 px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
              />
              <button
                phx-click="ingredient_search"
                phx-value-ingredients=""
                onclick="this.setAttribute('phx-value-ingredients', document.getElementById('ingredients-input').value)"
                class="bg-green-600 hover:bg-green-700 text-white px-6 py-3 rounded-lg font-medium transition-colors"
                disabled={@loading}
              >
                🥘 Find Recipes
              </button>
            </div>
          </div>
        </div>
        
    <!-- Error Display -->
        <%= if @error do %>
          <div class="bg-red-50 border border-red-200 rounded-lg p-4 mb-6">
            <p class="text-red-800 font-medium">Error</p>
            <p class="text-red-600 text-sm">{@error}</p>
          </div>
        <% end %>
        
    <!-- Results -->
        <%= if @loading do %>
          <div class="text-center py-12">
            <div class="inline-block animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600">
            </div>
            <p class="mt-4 text-gray-600">Searching recipes...</p>
          </div>
        <% else %>
          <%= if length(@results) > 0 do %>
            <div class="mb-4">
              <h2 class="text-xl font-semibold text-gray-900">
                Found {length(@results)} recipes
              </h2>
            </div>

            <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
              <%= for result <- @results do %>
                <div class="bg-white rounded-lg shadow-md hover:shadow-lg transition-shadow overflow-hidden">
                  <div class="p-6">
                    {render_recipe(assigns, result)}
                  </div>
                </div>
              <% end %>
            </div>
          <% else %>
            <%= unless @query == "" do %>
              <div class="text-center py-12">
                <p class="text-gray-500">No recipes found for "{@query}"</p>
                <p class="text-sm text-gray-400 mt-2">Try different keywords or ingredients</p>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp render_recipe(assigns, result) do
    # Extract recipe details from the text
    lines = String.split(result.text, "\n")
    title = extract_title(lines)
    servings = extract_servings(lines)
    ingredients = extract_ingredients(lines)
    nutrition = extract_nutrition(lines)
    categories = extract_categories(lines)
    url = extract_url(lines)

    assigns =
      assign(assigns, :recipe_data, %{
        title: title,
        servings: servings,
        ingredients: ingredients,
        nutrition: nutrition,
        categories: categories,
        url: url,
        score: result.score || result.semantic_score
      })

    ~H"""
    <div>
      <h3 class="font-semibold text-lg text-gray-900 mb-2 line-clamp-2">
        {@recipe_data.title}
      </h3>

      <div class="text-sm text-gray-600 mb-3">
        <%= if @recipe_data.servings do %>
          <span class="inline-block bg-blue-100 text-blue-800 px-2 py-1 rounded-full text-xs mr-2">
            🍽️ {@recipe_data.servings} servings
          </span>
        <% end %>

        <span class="inline-block bg-gray-100 text-gray-800 px-2 py-1 rounded-full text-xs">
          🎯 Score: {Float.round(@recipe_data.score * 100, 1)}%
        </span>
      </div>

      <%= if @recipe_data.ingredients && length(@recipe_data.ingredients) > 0 do %>
        <div class="mb-3">
          <h4 class="font-medium text-sm text-gray-800 mb-1">Ingredients:</h4>
          <ul class="text-xs text-gray-600 space-y-1">
            <%= for ingredient <- Enum.take(@recipe_data.ingredients, 5) do %>
              <li>{ingredient}</li>
            <% end %>
            <%= if length(@recipe_data.ingredients) > 5 do %>
              <li class="text-gray-400">... and {length(@recipe_data.ingredients) - 5} more</li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <%= if @recipe_data.nutrition do %>
        <div class="mb-3">
          <p class="text-xs text-gray-600"><strong>Nutrition:</strong> {@recipe_data.nutrition}</p>
        </div>
      <% end %>

      <%= if @recipe_data.categories do %>
        <div class="mb-3">
          <p class="text-xs text-gray-500"><strong>Categories:</strong> {@recipe_data.categories}</p>
        </div>
      <% end %>

      <%= if @recipe_data.url do %>
        <a
          href={@recipe_data.url}
          target="_blank"
          class="inline-block bg-blue-600 hover:bg-blue-700 text-white text-xs px-3 py-1 rounded transition-colors"
        >
          View Recipe →
        </a>
      <% end %>
    </div>
    """
  end

  defp extract_title(lines) do
    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, "Recipe: ") do
        String.replace_prefix(line, "Recipe: ", "")
      end
    end) || "Untitled Recipe"
  end

  defp extract_servings(lines) do
    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, "Servings: ") do
        String.replace_prefix(line, "Servings: ", "")
      end
    end)
  end

  defp extract_ingredients(lines) do
    # Find ingredients section
    ingredients_start = Enum.find_index(lines, &(&1 == "Ingredients:"))

    if ingredients_start do
      lines
      |> Enum.drop(ingredients_start + 1)
      |> Enum.take_while(&(String.starts_with?(&1, "- ") or &1 == ""))
      |> Enum.filter(&String.starts_with?(&1, "- "))
      |> Enum.map(&String.replace_prefix(&1, "- ", ""))
    else
      []
    end
  end

  defp extract_nutrition(lines) do
    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, "Nutrition: ") do
        String.replace_prefix(line, "Nutrition: ", "")
      end
    end)
  end

  defp extract_categories(lines) do
    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, "Categories: ") do
        String.replace_prefix(line, "Categories: ", "")
      end
    end)
  end

  defp extract_url(lines) do
    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, "URL: ") do
        String.replace_prefix(line, "URL: ", "")
      end
    end)
  end
end
