defmodule LidlChefWeb.RecipeLive do
  use LidlChefWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:loading, false)
     |> assign(:error, nil)
     |> assign(:search_mode, :natural)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    query = String.trim(query)

    if query != "" do
      case socket.assigns.search_mode do
        :natural ->
          send(self(), {:perform_search, query})
        :ingredients ->
          ingredient_list =
            query
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.filter(&(&1 != ""))

          if length(ingredient_list) > 0 do
            send(self(), {:perform_ingredient_search, ingredient_list})
          end
      end

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
  def handle_event("toggle_search_mode", _params, socket) do
    new_mode = if socket.assigns.search_mode == :natural, do: :ingredients, else: :natural
    {:noreply, assign(socket, :search_mode, new_mode)}
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
      <div class="flex-1 bg-base-100">
        <%!-- Hero Search Section --%>
        <div class="bg-gradient-to-b from-base-200/50 to-base-100 py-12 sm:py-16">
          <div class="max-w-4xl mx-auto px-4 sm:px-6">
            <div class="text-center mb-8">
              <h1 class="text-3xl sm:text-4xl font-bold text-base-content mb-3">
                Encuentra tu receta perfecta
              </h1>
              <p class="text-base-content/60 max-w-xl mx-auto">
                Busca entre más de 1,500 recetas usando búsqueda semántica con IA
              </p>
            </div>

            <%!-- Search Mode Toggle --%>
            <div class="flex items-center justify-center gap-3 mb-6">
              <span class={[
                "text-sm font-medium transition-colors",
                @search_mode == :natural && "text-[#0050AA]",
                @search_mode != :natural && "text-base-content/50"
              ]}>
                Búsqueda natural
              </span>
              <button
                type="button"
                phx-click="toggle_search_mode"
                class={[
                  "relative inline-flex h-7 w-14 items-center rounded-full transition-colors",
                  @search_mode == :natural && "bg-[#0050AA]",
                  @search_mode == :ingredients && "bg-[#FFF000]"
                ]}
              >
                <span class={[
                  "inline-block h-5 w-5 transform rounded-full bg-white shadow-md transition-transform",
                  @search_mode == :natural && "translate-x-1",
                  @search_mode == :ingredients && "translate-x-8"
                ]} />
              </button>
              <span class={[
                "text-sm font-medium transition-colors",
                @search_mode == :ingredients && "text-[#0050AA]",
                @search_mode != :ingredients && "text-base-content/50"
              ]}>
                Por ingredientes
              </span>
            </div>

            <%!-- Main Search --%>
            <.form for={%{}} as={:search} phx-submit="search" id="search-form">
              <div class="relative">
                <div class="absolute inset-y-0 left-0 pl-4 flex items-center pointer-events-none">
                  <%= if @search_mode == :natural do %>
                    <.icon name="hero-magnifying-glass" class="w-5 h-5 text-base-content/40" />
                  <% else %>
                    <.icon name="hero-beaker" class="w-5 h-5 text-base-content/40" />
                  <% end %>
                </div>
                <input
                  type="text"
                  name="search[query]"
                  value={@query}
                  placeholder={if @search_mode == :natural, do: "Busca recetas... (ej: 'pasta con verduras', 'cena rápida con pollo')", else: "Introduce ingredientes separados por comas (ej: pollo, tomate, cebolla)"}
                  class={[
                    "w-full pl-12 pr-32 py-4 bg-base-100 border rounded-2xl text-base-content placeholder-base-content/40 focus:outline-none focus:ring-2 transition-all",
                    @search_mode == :natural && "border-base-300 focus:ring-[#0050AA]/20 focus:border-[#0050AA]",
                    @search_mode == :ingredients && "border-[#FFF000]/50 focus:ring-[#FFF000]/30 focus:border-[#FFF000]"
                  ]}
                />
                <div class="absolute inset-y-0 right-2 flex items-center">
                  <button
                    type="submit"
                    class={[
                      "px-6 py-2.5 rounded-xl font-medium transition-all text-sm",
                      @search_mode == :natural && "bg-[#0050AA] hover:bg-[#003d80] text-white",
                      @search_mode == :ingredients && "bg-[#FFF000] hover:bg-yellow-400 text-[#0050AA]"
                    ]}
                    disabled={@loading}
                  >
                    <%= if @loading do %>
                      Buscando...
                    <% else %>
                      Buscar
                    <% end %>
                  </button>
                </div>
              </div>
            </.form>

            <%!-- Helper text --%>
            <p class="text-center text-xs text-base-content/50 mt-3">
              <%= if @search_mode == :natural do %>
                <.icon name="hero-sparkles" class="w-3 h-3 inline-block mr-1" />
                Describe lo que te apetece cocinar en lenguaje natural
              <% else %>
                <.icon name="hero-shopping-bag" class="w-3 h-3 inline-block mr-1" />
                Encontraremos recetas que puedas preparar con tus ingredientes
              <% end %>
            </p>
          </div>
        </div>

        <%!-- Results Section --%>
        <div class="max-w-7xl mx-auto px-4 sm:px-6 py-8">
          <%!-- Error Display --%>
          <%= if @error do %>
            <div class="mb-6 p-4 bg-[#E60A14]/10 border border-[#E60A14]/20 rounded-xl">
              <p class="text-[#E60A14] font-medium text-sm">{@error}</p>
            </div>
          <% end %>

          <%!-- Loading State --%>
          <%= if @loading do %>
            <div class="flex flex-col items-center justify-center py-20">
              <div class="w-12 h-12 border-4 border-[#0050AA]/20 border-t-[#0050AA] rounded-full animate-spin"></div>
              <p class="mt-4 text-base-content/60">Buscando recetas...</p>
            </div>
          <% else %>
            <%= if length(@results) > 0 do %>
              <%!-- Results Header --%>
              <div class="flex items-center justify-between mb-6">
                <h2 class="text-lg font-semibold text-base-content">
                  Encontradas <span class="text-[#0050AA]">{length(@results)}</span> recetas
                </h2>
              </div>

              <%!-- Results Grid --%>
              <div class="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
                <%= for result <- @results do %>
                  {render_recipe(assigns, result)}
                <% end %>
              </div>
            <% else %>
              <%= if @query == "" do %>
                <%!-- Empty State --%>
                <div class="text-center py-16">
                  <div class="w-20 h-20 bg-base-200 rounded-2xl flex items-center justify-center mx-auto mb-6">
                    <.icon name="hero-magnifying-glass" class="w-10 h-10 text-base-content/30" />
                  </div>
                  <h3 class="text-lg font-semibold text-base-content mb-2">Empieza a buscar</h3>
                  <p class="text-base-content/60 max-w-md mx-auto">
                    Introduce el nombre de una receta, ingrediente o describe lo que te apetece
                  </p>
                </div>
              <% else %>
                <%!-- No Results --%>
                <div class="text-center py-16">
                  <div class="w-20 h-20 bg-base-200 rounded-2xl flex items-center justify-center mx-auto mb-6">
                    <.icon name="hero-face-frown" class="w-10 h-10 text-base-content/30" />
                  </div>
                  <h3 class="text-lg font-semibold text-base-content mb-2">No se encontraron recetas</h3>
                  <p class="text-base-content/60">
                    Prueba con otras palabras clave o revisa la ortografía
                  </p>
                </div>
              <% end %>
            <% end %>
          <% end %>
        </div>
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
    categories = extract_categories(lines)
    url = extract_url(lines)

    assigns =
      assign(assigns, :recipe_data, %{
        title: title,
        servings: servings,
        ingredients: ingredients,
        categories: categories,
        url: url,
        score: result.score || result.semantic_score
      })

    ~H"""
    <article class="group bg-base-100 border border-base-200 rounded-2xl overflow-hidden hover:border-[#0050AA]/30 hover:shadow-lg transition-all">
      <%!-- Card Header with accent --%>
      <div class="h-2 bg-gradient-to-r from-[#0050AA] to-[#0066cc]"></div>

      <div class="p-5">
        <%!-- Title --%>
        <h3 class="font-semibold text-lg text-base-content mb-3 line-clamp-2 group-hover:text-[#0050AA] transition-colors">
          {@recipe_data.title}
        </h3>

        <%!-- Meta badges --%>
        <div class="flex flex-wrap gap-2 mb-4">
          <%= if @recipe_data.servings do %>
            <span class="inline-flex items-center gap-1 bg-base-200 text-base-content/70 px-2.5 py-1 rounded-lg text-xs">
              <.icon name="hero-users" class="w-3.5 h-3.5" />
              {@recipe_data.servings}
            </span>
          <% end %>
          <span class="inline-flex items-center gap-1 bg-[#0050AA]/10 text-[#0050AA] px-2.5 py-1 rounded-lg text-xs font-medium">
            <.icon name="hero-sparkles" class="w-3.5 h-3.5" />
            {Float.round(@recipe_data.score * 100, 0)}% match
          </span>
        </div>

        <%!-- Ingredients Preview --%>
        <%= if @recipe_data.ingredients && length(@recipe_data.ingredients) > 0 do %>
          <div class="mb-4">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-2">Ingredientes</p>
            <div class="flex flex-wrap gap-1.5">
              <%= for ingredient <- Enum.take(@recipe_data.ingredients, 4) do %>
                <span class="bg-base-200 text-base-content/70 px-2 py-0.5 rounded text-xs">
                  {ingredient |> String.slice(0..20)}<%= if String.length(ingredient) > 20, do: "..." %>
                </span>
              <% end %>
              <%= if length(@recipe_data.ingredients) > 4 do %>
                <span class="bg-base-200 text-base-content/50 px-2 py-0.5 rounded text-xs">
                  +{length(@recipe_data.ingredients) - 4} más
                </span>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Categories --%>
        <%= if @recipe_data.categories do %>
          <p class="text-xs text-base-content/50 mb-4 line-clamp-1">
            {@recipe_data.categories}
          </p>
        <% end %>

        <%!-- Action Button --%>
        <%= if @recipe_data.url do %>
          <a
            href={@recipe_data.url}
            target="_blank"
            class="inline-flex items-center gap-2 w-full justify-center bg-[#0050AA] hover:bg-[#003d80] text-white text-sm font-medium px-4 py-2.5 rounded-xl transition-all"
          >
            Ver Receta
            <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
          </a>
        <% end %>
      </div>
    </article>
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
