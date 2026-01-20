defmodule LidlChefWeb.ProductDetailLive do
  use LidlChefWeb, :live_view

  alias Arcana.Graph.GraphStore
  alias LidlChef.Repo

  import Ecto.Query

  @impl true
  def mount(%{"wawi_id" => wawi_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:wawi_id, wawi_id)
     |> assign(:product, nil)
     |> assign(:graph_data, nil)
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> load_product_and_graph()}
  end

  defp load_product_and_graph(socket) do
    wawi_id = socket.assigns.wawi_id

    # Find the product document by wawi_id in metadata
    case find_product_by_wawi_id(wawi_id) do
      {:ok, product} ->
        # Build the graph data for this product
        graph_data = build_graph_data(product, wawi_id)

        socket
        |> assign(:product, product)
        |> assign(:graph_data, graph_data)
        |> assign(:loading, false)

      {:error, :not_found} ->
        socket
        |> assign(:loading, false)
        |> assign(:error, "Producto no encontrado con Wawi ID: #{wawi_id}")
    end
  end

  defp find_product_by_wawi_id(wawi_id) do
    query =
      from d in Arcana.Document,
        join: c in Arcana.Collection,
        on: d.collection_id == c.id,
        where: c.name == "products",
        where: fragment("?->>'wawi_id' = ?", d.metadata, ^wawi_id),
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  defp build_graph_data(product, wawi_id) do
    # Get the product title from metadata
    product_title = product.metadata["title"] || product.metadata["erpName"]
    collection_id = get_products_collection_id()

    if is_nil(collection_id) do
      minimal_graph(product_title, wawi_id)
    else
      # Strategy: Find the wawiId entity and traverse relationships
      case find_wawi_entity(wawi_id, collection_id) do
        nil ->
          # Fallback: try to find the product by title
          case find_product_entity(product_title, collection_id) do
            nil -> minimal_graph(product_title, wawi_id)
            product_entity -> build_graph_from_entity(product_entity, product_title, wawi_id)
          end

        wawi_entity ->
          # Find the product entity connected to this wawiId
          build_graph_from_wawi_entity(wawi_entity, product_title, wawi_id)
      end
    end
  end

  defp minimal_graph(product_title, wawi_id) do
    %{
      nodes: [
        %{
          id: "product_#{wawi_id}",
          name: product_title || "Producto #{wawi_id}",
          type: "product",
          description: "Wawi ID: #{wawi_id}"
        }
      ],
      links: []
    }
  end

  defp find_wawi_entity(wawi_id, collection_id) do
    # Find entity with type wawiid and name matching the wawi_id
    GraphStore.list_entities(
      repo: Repo,
      collection_id: collection_id,
      type: "wawiid",
      search: wawi_id,
      limit: 1
    )
    |> List.first()
  end

  defp find_product_entity(product_title, collection_id) when is_binary(product_title) do
    # Try to find by producterpname or producttitle
    GraphStore.list_entities(
      repo: Repo,
      collection_id: collection_id,
      search: product_title,
      limit: 10
    )
    |> Enum.find(fn e ->
      type = normalize_type(e.type)
      type in ["producterpname", "producttitle", "product"] &&
        String.downcase(e.name || "") == String.downcase(product_title)
    end)
  end

  defp find_product_entity(_, _), do: nil

  defp build_graph_from_wawi_entity(wawi_entity, product_title, wawi_id) do
    # Get relationships from the wawiId entity
    wawi_relationships = GraphStore.get_relationships(wawi_entity.id, repo: Repo)

    # Find the product entity connected via HAS_WAWI_ID
    product_entity =
      wawi_relationships
      |> Enum.find_value(fn rel ->
        if rel.type == "HAS_WAWI_ID" do
          case GraphStore.get_entity(rel.source_id, repo: Repo) do
            {:ok, entity} -> entity
            _ -> nil
          end
        end
      end)

    if product_entity do
      build_graph_from_entity(product_entity, product_title, wawi_id)
    else
      # Build graph starting from wawi_entity
      build_graph_from_entity(wawi_entity, product_title, wawi_id)
    end
  end

  defp build_graph_from_entity(root_entity, product_title, wawi_id) do
    # Get all relationships for the root entity
    relationships = GraphStore.get_relationships(root_entity.id, repo: Repo)

    # Collect all connected entity IDs
    connected_ids =
      relationships
      |> Enum.flat_map(fn rel -> [rel.source_id, rel.target_id] end)
      |> Enum.uniq()

    # Fetch all connected entities
    connected_entities =
      connected_ids
      |> Enum.map(fn id ->
        case GraphStore.get_entity(id, repo: Repo) do
          {:ok, entity} -> entity
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Filter entities that should NOT be traversed further to avoid graph explosion
    # Categories, brands, and other high-connectivity nodes should not expand
    traversable_entities =
      connected_entities
      |> Enum.reject(fn entity ->
        type = normalize_type(entity.type)
        # Don't traverse from categories, brands, or other hub nodes
        type in ["category", "brand", "productline"]
      end)

    # Now get secondary relationships (relationships of connected entities)
    # Only for traversable entities to avoid pulling in hundreds of unrelated nodes
    secondary_relationships =
      traversable_entities
      |> Enum.flat_map(fn entity ->
        GraphStore.get_relationships(entity.id, repo: Repo)
      end)
      |> Enum.uniq_by(& &1.id)

    # Collect all entity IDs from secondary relationships
    all_entity_ids =
      (relationships ++ secondary_relationships)
      |> Enum.flat_map(fn rel -> [rel.source_id, rel.target_id] end)
      |> Enum.uniq()

    # Fetch any missing entities
    all_entities =
      all_entity_ids
      |> Enum.map(fn id ->
        existing = Enum.find(connected_entities, fn e -> e.id == id end)

        if existing do
          existing
        else
          case GraphStore.get_entity(id, repo: Repo) do
            {:ok, entity} -> entity
            _ -> nil
          end
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    # Build the final graph
    build_graph(all_entities, relationships ++ secondary_relationships, product_title, wawi_id)
  end

  defp build_graph(entities, relationships, product_title, wawi_id) do
    # Build nodes from entities
    nodes =
      entities
      |> Enum.map(fn entity ->
        %{
          id: entity.id,
          name: entity.name,
          type: normalize_type(entity.type),
          description: entity.description
        }
      end)

    # Ensure we have a product node if none exists
    product_node_exists =
      Enum.any?(nodes, fn n ->
        n.type in ["product", "producterpname", "producttitle"]
      end)

    nodes =
      if product_node_exists do
        nodes
      else
        [
          %{
            id: "product_#{wawi_id}",
            name: product_title || "Producto #{wawi_id}",
            type: "product",
            description: "Wawi ID: #{wawi_id}"
          }
          | nodes
        ]
      end

    # Build links from relationships
    node_ids = MapSet.new(Enum.map(nodes, & &1.id))

    links =
      relationships
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(fn rel ->
        MapSet.member?(node_ids, rel.source_id) && MapSet.member?(node_ids, rel.target_id)
      end)
      |> Enum.map(fn rel ->
        %{
          source: rel.source_id,
          target: rel.target_id,
          type: rel.type,
          strength: rel.strength || 5
        }
      end)

    %{nodes: nodes, links: links}
  end

  defp get_products_collection_id do
    query = from c in Arcana.Collection, where: c.name == "products", select: c.id
    Repo.one(query)
  end

  defp normalize_type(nil), do: "other"
  defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_type(type) when is_binary(type), do: String.downcase(type)

  @impl true
  def handle_event("node-clicked", %{"id" => _id, "name" => name, "type" => type}, socket) do
    # Could expand to show more details about the clicked node
    {:noreply,
     socket
     |> put_flash(:info, "Nodo seleccionado: #{name} (#{type})")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="flex-1 bg-base-100">
        <%!-- Header --%>
        <div class="bg-gradient-to-b from-base-200/50 to-base-100 py-8 sm:py-12">
          <div class="max-w-6xl mx-auto px-4 sm:px-6">
            <.link
              navigate={~p"/products"}
              class="inline-flex items-center gap-2 text-base-content/60 hover:text-base-content mb-4 transition-colors"
            >
              <.icon name="hero-arrow-left-mini" class="w-4 h-4" />
              Volver a productos
            </.link>

            <div :if={@loading} class="flex items-center gap-3">
              <div class="loading loading-spinner loading-md"></div>
              <span class="text-base-content/60">Cargando producto...</span>
            </div>

            <div :if={@error && !@loading} class="bg-error/10 border border-error/20 rounded-xl p-4">
              <p class="text-error">{@error}</p>
            </div>

            <div :if={@product && !@loading}>
              <h1 class="text-2xl sm:text-3xl font-bold text-base-content mb-2">
                {@product.metadata["title"] || "Producto"}
              </h1>
              <div class="flex items-center gap-3 flex-wrap">
                <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-[#0050AA]/10 text-[#0050AA]">
                  {@product.metadata["product_line"] || "Producto"}
                </span>
                <span class="text-base-content/60 text-sm">
                  Wawi ID: {@wawi_id}
                </span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Graph Section --%>
        <div :if={@product && !@loading} class="max-w-6xl mx-auto px-4 sm:px-6 pb-12">
          <div class="bg-base-100 border border-base-300 rounded-2xl overflow-hidden shadow-sm">
            <div class="p-4 border-b border-base-200 flex items-center justify-between">
              <div>
                <h2 class="font-semibold text-base-content">Grafo de Conocimiento</h2>
                <p class="text-sm text-base-content/60">
                  Visualización de entidades y relaciones del producto
                </p>
              </div>
              <div class="flex items-center gap-2 text-sm text-base-content/60">
                <span>
                  {length(@graph_data.nodes)} nodos
                </span>
                <span>•</span>
                <span>
                  {length(@graph_data.links)} relaciones
                </span>
              </div>
            </div>

            <div
              id="knowledge-graph"
              phx-hook="KnowledgeGraph"
              phx-update="ignore"
              data-graph-data={Jason.encode!(@graph_data)}
              class="w-full h-[600px] bg-gradient-to-br from-base-100 to-base-200/30"
            >
            </div>
          </div>

          <%!-- Product Details Card --%>
          <div class="mt-6 bg-base-100 border border-base-300 rounded-2xl p-6">
            <h3 class="font-semibold text-base-content mb-4">Detalles del Producto</h3>

            <div :if={@product.metadata["bullet_points"]} class="prose prose-sm max-w-none">
              <div class="text-base-content/80 whitespace-pre-wrap text-sm">
                {@product.metadata["bullet_points"]}
              </div>
            </div>

            <div :if={!@product.metadata["bullet_points"]} class="text-base-content/60 text-sm">
              No hay detalles adicionales disponibles para este producto.
            </div>
          </div>

          <%!-- Graph Stats --%>
          <div class="mt-6 grid grid-cols-2 sm:grid-cols-4 gap-4">
            <.stat_card
              label="Ingredientes"
              value={count_nodes_by_type(@graph_data.nodes, "ingredient")}
              icon="hero-beaker"
            />
            <.stat_card
              label="Alérgenos"
              value={count_nodes_by_type(@graph_data.nodes, "allergen")}
              icon="hero-exclamation-triangle"
            />
            <.stat_card
              label="Certificaciones"
              value={count_nodes_by_type(@graph_data.nodes, "certification")}
              icon="hero-check-badge"
            />
            <.stat_card
              label="Orígenes"
              value={count_nodes_by_type(@graph_data.nodes, "origin")}
              icon="hero-globe-alt"
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-300 rounded-xl p-4">
      <div class="flex items-center gap-3">
        <div class="w-10 h-10 bg-base-200 rounded-lg flex items-center justify-center">
          <.icon name={@icon} class="w-5 h-5 text-base-content/60" />
        </div>
        <div>
          <div class="text-2xl font-bold text-base-content">{@value}</div>
          <div class="text-sm text-base-content/60">{@label}</div>
        </div>
      </div>
    </div>
    """
  end

  defp count_nodes_by_type(nodes, type) do
    Enum.count(nodes, fn n -> n.type == type end)
  end
end
