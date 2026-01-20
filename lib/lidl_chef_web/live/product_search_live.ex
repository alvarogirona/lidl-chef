defmodule LidlChefWeb.ProductSearchLive do
  use LidlChefWeb, :live_view

  alias LidlChef.ProductSearch

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
    query = String.trim(query)

    if query != "" do
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
  def handle_info({:perform_search, query}, socket) do
    case ProductSearch.search(query, graph: false, limit: 20) do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:results, results)
         |> assign(:loading, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:results, [])
         |> assign(:loading, false)
         |> assign(:error, "La búsqueda ha fallado: #{inspect(reason)}")}
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
            <div class="text-center mb-6">
              <h1 class="text-3xl sm:text-4xl font-bold text-base-content mb-3">
                🛒 Busca productos
              </h1>
              <p class="text-base-content/60 max-w-xl mx-auto">
                Encuentra productos de Lidl por nombre, ingredientes o características
              </p>
            </div>

            <%!-- Main Search --%>
            <.form for={%{}} as={:search} phx-submit="search" id="product-search-form">
              <div class="relative">
                <div class="absolute inset-y-0 left-0 pl-4 flex items-center pointer-events-none">
                  <.icon name="hero-magnifying-glass" class="h-5 w-5 text-base-content/40" />
                </div>
                <input
                  type="text"
                  name="search[query]"
                  value={@query}
                  placeholder="Busca productos: croissant, leche, sin gluten..."
                  class="w-full pl-12 pr-4 py-4 text-lg bg-base-100 border border-base-300 rounded-2xl focus:outline-none focus:ring-2 focus:ring-[#0050AA] focus:border-transparent shadow-sm"
                  autocomplete="off"
                />
                <div class="absolute inset-y-0 right-0 pr-3 flex items-center">
                  <button
                    type="submit"
                    class="bg-[#0050AA] text-white px-6 py-2.5 rounded-xl font-medium hover:bg-[#003d82] transition-colors"
                  >
                    Buscar
                  </button>
                </div>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Results Section --%>
        <div class="max-w-6xl mx-auto px-4 sm:px-6 pb-12">
          <%!-- Loading State --%>
          <div :if={@loading} class="flex items-center justify-center py-20">
            <div class="flex items-center gap-3 text-base-content/60">
              <div class="loading loading-spinner loading-md"></div>
              <span>Buscando productos...</span>
            </div>
          </div>

          <%!-- Error State --%>
          <div
            :if={@error && !@loading}
            class="bg-error/10 border border-error/20 rounded-xl p-4 mb-6"
          >
            <p class="text-error text-sm">{@error}</p>
          </div>

          <%!-- Results Grid --%>
          <div :if={!@loading && @results != []} class="space-y-4">
            <div class="flex items-center justify-between mb-6">
              <h2 class="text-xl font-semibold text-base-content">
                {length(@results)} productos encontrados
              </h2>
            </div>

            <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
              <.product_card :for={result <- @results} result={result} />
            </div>
          </div>

          <%!-- Empty State --%>
          <div
            :if={!@loading && @results == [] && @query != ""}
            class="text-center py-20"
          >
            <div class="w-16 h-16 bg-base-200 rounded-full flex items-center justify-center mx-auto mb-4">
              <.icon name="hero-shopping-bag" class="w-8 h-8 text-base-content/40" />
            </div>
            <h3 class="text-lg font-medium text-base-content mb-2">
              No se encontraron productos
            </h3>
            <p class="text-base-content/60">
              Intenta con otros términos de búsqueda
            </p>
          </div>

          <%!-- Initial State --%>
          <div :if={!@loading && @query == ""} class="text-center py-20">
            <div class="w-16 h-16 bg-[#0050AA]/10 rounded-2xl flex items-center justify-center mx-auto mb-4">
              <span class="text-3xl">🛍️</span>
            </div>
            <h3 class="text-lg font-medium text-base-content mb-2">
              Explora nuestro catálogo de productos
            </h3>
            <p class="text-base-content/60 mb-6">
              Busca por nombre, ingredientes, alérgenos o cualquier característica
            </p>
            <div class="flex flex-wrap gap-2 justify-center">
              <button
                type="button"
                phx-click="search"
                phx-value-search[query]="croissant"
                class="px-4 py-2 bg-base-200 rounded-lg text-sm hover:bg-base-300 transition-colors"
              >
                croissant
              </button>
              <button
                type="button"
                phx-click="search"
                phx-value-search[query]="sin gluten"
                class="px-4 py-2 bg-base-200 rounded-lg text-sm hover:bg-base-300 transition-colors"
              >
                sin gluten
              </button>
              <button
                type="button"
                phx-click="search"
                phx-value-search[query]="leche"
                class="px-4 py-2 bg-base-200 rounded-lg text-sm hover:bg-base-300 transition-colors"
              >
                leche
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp product_card(assigns) do
    metadata = assigns.result.metadata || %{}
    wawi_id = metadata["wawi_id"]
    title = metadata["product_title"] || metadata["title"] || "Producto"
    product_line = metadata["product_line"]
    # Get a preview of the product content
    text_preview =
      case assigns.result do
        %{text: text} when is_binary(text) ->
          text |> String.slice(0, 120) |> String.trim()
        _ ->
          nil
      end

    assigns =
      assigns
      |> assign(:wawi_id, wawi_id)
      |> assign(:title, title)
      |> assign(:product_line, product_line)
      |> assign(:text_preview, text_preview)

    ~H"""
    <.link
      :if={@wawi_id}
      navigate={~p"/products/#{@wawi_id}"}
      class="block bg-base-100 border border-base-300 rounded-xl p-4 hover:shadow-lg hover:border-[#0050AA]/30 transition-all group"
    >
      <div class="flex items-start gap-3">
        <div class="w-12 h-12 bg-[#0050AA]/10 rounded-xl flex items-center justify-center flex-shrink-0 group-hover:bg-[#0050AA]/20 transition-colors">
          <.icon name="hero-cube" class="w-6 h-6 text-[#0050AA]" />
        </div>
        <div class="flex-1 min-w-0">
          <h3 class="font-semibold text-base-content line-clamp-2 mb-2 group-hover:text-[#0050AA] transition-colors">
            {@title}
          </h3>
          <p :if={@text_preview} class="text-sm text-base-content/60 line-clamp-2 mb-3">
            {@text_preview}
          </p>
          <div class="flex items-center gap-2 flex-wrap">
            <span
              :if={@product_line}
              class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-[#0050AA]/10 text-[#0050AA]"
            >
              {@product_line}
            </span>
            <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-base-200 text-base-content/60">
              ID: {@wawi_id}
            </span>
          </div>
        </div>
        <div class="flex-shrink-0">
          <.icon name="hero-arrow-right" class="w-5 h-5 text-base-content/40 group-hover:text-[#0050AA] group-hover:translate-x-1 transition-all" />
        </div>
      </div>
    </.link>

    <div
      :if={!@wawi_id}
      class="bg-base-100 border border-base-300 rounded-xl p-4 opacity-60"
    >
      <div class="flex items-start gap-3">
        <div class="w-12 h-12 bg-base-200 rounded-xl flex items-center justify-center flex-shrink-0">
          <.icon name="hero-cube" class="w-6 h-6 text-base-content/40" />
        </div>
        <div class="flex-1 min-w-0">
          <h3 class="font-semibold text-base-content line-clamp-2 mb-2">{@title}</h3>
          <p class="text-sm text-base-content/60">Sin ID de producto disponible</p>
        </div>
      </div>
    </div>
    """
  end
end
