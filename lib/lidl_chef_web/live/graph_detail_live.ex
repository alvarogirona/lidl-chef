defmodule LidlChefWeb.GraphDetailLive do
  use LidlChefWeb, :live_view

  alias Arcana.Graph.GraphStore
  alias LidlChef.Repo

  import Ecto.Query

  @impl true
  def mount(%{"entity_id" => id_param}, _session, socket) do
    {:ok,
     socket
     |> assign(:id_param, id_param)
     |> assign(:entity, nil)
     |> assign(:product, nil)
     |> assign(:graph_data, nil)
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:depth, 1)
     |> assign(:selected_node, nil)
     |> assign(:selected_node_relationships, [])
     |> load_entity_and_graph()}
  end

  defp load_entity_and_graph(socket) do
    id_param = socket.assigns.id_param
    depth = socket.assigns.depth

    # Detect if this is a wawi_id (numeric) or entity_id (UUID)
    entity_result =
      if String.match?(id_param, ~r/^\d+$/), do: find_entity_by_wawi_id(id_param), else: find_entity_by_id(id_param)

    case entity_result do
      {:ok, entity, product} ->
        # Build the graph data for this entity with specified depth
        graph_data = build_graph_data(entity, depth)

        socket
        |> assign(:entity, entity)
        |> assign(:product, product)
        |> assign(:graph_data, graph_data)
        |> assign(:loading, false)

      {:error, reason} ->
        socket
        |> assign(:loading, false)
        |> assign(:error, reason)
    end
  end

  defp find_entity_by_id(entity_id) do
    # Direct entity lookup
    case GraphStore.get_entity(entity_id, repo: Repo) do
      {:ok, entity} -> {:ok, entity, nil}
      {:error, _} -> {:error, "Entidad no encontrada con ID: #{entity_id}"}
    end
  end

  defp find_entity_by_wawi_id(wawi_id) do
    # First find the product document
    query =
      from d in Arcana.Document,
        join: c in Arcana.Collection,
        on: d.collection_id == c.id,
        where: c.name == "products",
        where: fragment("?->>'wawi_id' = ?", d.metadata, ^wawi_id),
        limit: 1

    product = Repo.one(query)

    if product do
      # Find the product entity in the graph
      collection_id = get_products_collection_id()
      product_title = product.metadata["title"] || product.metadata["erpName"]

      # Try to find via wawiid entity first
      case find_wawi_entity(wawi_id, collection_id) do
        nil ->
          # Fallback: find by product title
          case find_product_entity(product_title, collection_id) do
            nil -> {:error, "Entidad no encontrada en el grafo para Wawi ID: #{wawi_id}"}
            entity -> {:ok, entity, product}
          end

        wawi_entity ->
          # Find the product entity connected to this wawiId
          case find_product_from_wawi_entity(wawi_entity) do
            nil -> {:ok, wawi_entity, product}
            product_entity -> {:ok, product_entity, product}
          end
      end
    else
      {:error, "Producto no encontrado con Wawi ID: #{wawi_id}"}
    end
  end

  defp find_wawi_entity(wawi_id, collection_id) do
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

  defp find_product_from_wawi_entity(wawi_entity) do
    wawi_relationships = GraphStore.get_relationships(wawi_entity.id, repo: Repo)

    wawi_relationships
    |> Enum.find_value(fn rel ->
      if rel.type == "HAS_WAWI_ID" do
        case GraphStore.get_entity(rel.source_id, repo: Repo) do
          {:ok, entity} -> entity
          _ -> nil
        end
      end
    end)
  end

  defp get_products_collection_id do
    query = from c in Arcana.Collection, where: c.name == "products", select: c.id
    Repo.one(query)
  end

  defp build_graph_data(root_entity, depth) do
    # Traverse relationships up to the specified depth
    {all_entities, all_relationships} = traverse_graph(root_entity, depth, MapSet.new(), [])

    # Build the final graph
    build_graph(all_entities, all_relationships, root_entity)
  end

  defp traverse_graph(_entity, 0, _visited, relationships) do
    # Depth limit reached
    {[], relationships}
  end

  defp traverse_graph(entity, depth, visited, relationships) do
    entity_id = entity.id

    # Skip if already visited
    if MapSet.member?(visited, entity_id) do
      {[entity], relationships}
    else
      visited = MapSet.put(visited, entity_id)

      # Get relationships for this entity
      entity_relationships = GraphStore.get_relationships(entity_id, repo: Repo)
      all_relationships = relationships ++ entity_relationships

      # Get connected entity IDs
      connected_ids =
        entity_relationships
        |> Enum.flat_map(fn rel -> [rel.source_id, rel.target_id] end)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == entity_id))

      # Fetch connected entities
      connected_entities =
        connected_ids
        |> Enum.map(fn id ->
          case GraphStore.get_entity(id, repo: Repo) do
            {:ok, entity} -> entity
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      # Filter entities that should NOT be traversed further
      traversable_entities =
        connected_entities
        |> Enum.reject(fn e ->
          type = normalize_type(e.type)
          # Don't traverse from categories, brands, or other hub nodes
          type in ["category", "brand", "productline"]
        end)

      # Recursively traverse (depth - 1) for traversable entities
      {nested_entities, nested_relationships} =
        if depth > 1 do
          traversable_entities
          |> Enum.reduce({[], all_relationships}, fn e, {entities_acc, rels_acc} ->
            {new_entities, new_rels} = traverse_graph(e, depth - 1, visited, rels_acc)
            {entities_acc ++ new_entities, new_rels}
          end)
        else
          {[], all_relationships}
        end

      # Combine all entities (current + connected + nested)
      all_entities =
        ([entity] ++ connected_entities ++ nested_entities)
        |> Enum.uniq_by(& &1.id)

      {all_entities, nested_relationships}
    end
  end

  defp build_graph(entities, relationships, root_entity) do
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
          strength: rel.strength || 5,
          metadata: rel[:metadata] || %{}
        }
      end)

    %{nodes: nodes, links: links, root_id: root_entity.id}
  end

  defp normalize_type(nil), do: "other"
  defp normalize_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_type(type) when is_binary(type), do: String.downcase(type)

  @impl true
  def handle_event("node-clicked", %{"id" => id, "name" => name, "type" => type}, socket) do
    # Fetch the entity and its relationships for the detail card
    case GraphStore.get_entity(id, repo: Repo) do
      {:ok, _entity} ->
        relationships = GraphStore.get_relationships(id, repo: Repo)

        # Get details about connected entities
        relationship_details =
          relationships
          |> Enum.take(5)
          |> Enum.map(fn rel ->
            # Get the other entity (not the selected one)
            other_id = if rel.source_id == id, do: rel.target_id, else: rel.source_id

            other_entity =
              case GraphStore.get_entity(other_id, repo: Repo) do
                {:ok, e} -> e
                _ -> nil
              end

            if other_entity do
              %{
                type: rel.type,
                direction: if(rel.source_id == id, do: :outgoing, else: :incoming),
                metadata: rel[:metadata] || %{},
                strength: rel.strength,
                entity: %{
                  id: other_entity.id,
                  name: other_entity.name,
                  type: normalize_type(other_entity.type)
                }
              }
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:noreply,
         socket
         |> assign(:selected_node, %{id: id, name: name, type: type})
         |> assign(:selected_node_relationships, relationship_details)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("close-detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_node, nil)
     |> assign(:selected_node_relationships, [])}
  end

  def handle_event("change-depth", %{"depth" => depth_str}, socket) do
    depth = String.to_integer(depth_str)

    socket =
      socket
      |> assign(:depth, depth)
      |> assign(:loading, true)
      |> load_entity_and_graph()

    # Push the new graph data to the JS hook since phx-update="ignore" prevents automatic updates
    {:noreply, push_event(socket, "graph-data", socket.assigns.graph_data)}
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
              <span class="text-base-content/60">Cargando entidad...</span>
            </div>

            <div :if={@error && !@loading} class="bg-error/10 border border-error/20 rounded-xl p-4">
              <p class="text-error">{@error}</p>
            </div>

            <div :if={@entity && !@loading}>
              <h1 class="text-2xl sm:text-3xl font-bold text-base-content mb-2">
                {@entity.name || "Entidad"}
              </h1>
              <div class="flex items-center gap-3 flex-wrap">
                <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-[#0050AA]/10 text-[#0050AA]">
                  {normalize_type(@entity.type)}
                </span>
                <span :if={@entity.description} class="text-base-content/60 text-sm">
                  {@entity.description}
                </span>
                <span :if={@product} class="text-base-content/60 text-sm">
                  Wawi ID: {@product.metadata["wawi_id"]}
                </span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Graph Section with Detail Card --%>
        <div :if={@entity && !@loading} class="max-w-6xl mx-auto px-4 sm:px-6 pb-12">
          <div class="relative">
            <%!-- Selected Node Detail Card - Redesigned --%>
            <div
              :if={@selected_node}
              class="absolute top-4 left-4 z-20 bg-white/95 backdrop-blur-sm border border-base-200 rounded-2xl shadow-xl max-w-sm w-96 animate-fade-in overflow-hidden"
            >
              <%!-- Card Header with gradient --%>
              <div class="bg-gradient-to-r from-[#0050AA] to-[#0070DD] p-4">
                <div class="flex items-start justify-between">
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 mb-1">
                      <span class="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-semibold bg-white/20 text-white uppercase tracking-wider">
                        {@selected_node.type}
                      </span>
                    </div>
                    <h3 class="font-bold text-white text-lg leading-tight">
                      {@selected_node.name}
                    </h3>
                  </div>
                  <div class="flex items-center gap-1 ml-2">
                    <.link
                      navigate={~p"/graph/#{@selected_node.id}"}
                      class="p-2 hover:bg-white/20 rounded-xl transition-all duration-200"
                      title="Ver grafo completo"
                    >
                      <.icon name="hero-arrow-top-right-on-square" class="w-5 h-5 text-white" />
                    </.link>
                    <button
                      phx-click="close-detail"
                      class="p-2 hover:bg-white/20 rounded-xl transition-all duration-200"
                    >
                      <.icon name="hero-x-mark" class="w-5 h-5 text-white" />
                    </button>
                  </div>
                </div>
              </div>

              <%!-- Card Body --%>
              <div class="p-4">
                <div :if={@selected_node_relationships != []} class="space-y-3">
                  <div class="flex items-center justify-between">
                    <p class="text-xs font-semibold text-base-content/60 uppercase tracking-wider">
                      Conexiones
                    </p>
                    <span class="text-xs text-base-content/40">
                      {length(@selected_node_relationships)} relaciones
                    </span>
                  </div>

                  <div class="space-y-2 max-h-72 overflow-y-auto pr-1">
                    <div
                      :for={rel <- @selected_node_relationships}
                      class="group relative bg-gradient-to-r from-base-100 to-base-50 border border-base-200 rounded-xl p-3 hover:border-[#0050AA]/30 hover:shadow-md transition-all duration-200"
                    >
                      <%!-- Relationship Type Badge --%>
                      <div class="flex items-center gap-2 mb-2">
                        <div class={[
                          "flex items-center justify-center w-6 h-6 rounded-lg",
                          if(rel.direction == :outgoing, do: "bg-emerald-100", else: "bg-blue-100")
                        ]}>
                          <.icon
                            name={if rel.direction == :outgoing, do: "hero-arrow-right-mini", else: "hero-arrow-left-mini"}
                            class={[
                              "w-4 h-4",
                              if(rel.direction == :outgoing, do: "text-emerald-600", else: "text-blue-600")
                            ]}
                          />
                        </div>
                        <span class="text-xs font-semibold text-base-content/70 uppercase tracking-wide">
                          {rel.type |> String.replace("_", " ")}
                        </span>
                      </div>

                      <%!-- Entity Info --%>
                      <div class="flex items-center gap-3">
                        <div class="flex-1 min-w-0">
                          <p class="font-medium text-base-content truncate">
                            {rel.entity.name}
                          </p>
                          <p class="text-xs text-base-content/50">
                            {rel.entity.type}
                          </p>
                        </div>
                      </div>

                      <%!-- Metadata Section --%>
                      <div :if={rel.metadata != %{} && map_size(rel.metadata) > 0} class="mt-3 pt-3 border-t border-base-200">
                        <div class="grid grid-cols-2 gap-2">
                          <div
                            :for={{key, value} <- rel.metadata}
                            :if={value != nil && value != ""}
                            class="bg-white rounded-lg px-2.5 py-1.5 border border-base-100"
                          >
                            <p class="text-[10px] text-base-content/50 uppercase tracking-wider font-medium">
                              {format_metadata_key(key)}
                            </p>
                            <p class="text-sm font-semibold text-base-content">
                              {format_metadata_value(value)}
                            </p>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>

                <div :if={@selected_node_relationships == []} class="text-center py-6">
                  <div class="w-12 h-12 mx-auto mb-3 bg-base-100 rounded-full flex items-center justify-center">
                    <.icon name="hero-link-slash" class="w-6 h-6 text-base-content/30" />
                  </div>
                  <p class="text-sm text-base-content/50">
                    No hay conexiones disponibles
                  </p>
                </div>
              </div>
            </div>

            <%!-- Graph Container --%>
            <div class="bg-base-100 border border-base-300 rounded-2xl overflow-hidden shadow-sm">
              <div class="p-4 border-b border-base-200">
                <div class="flex items-center justify-between mb-4">
                  <div>
                    <h2 class="font-semibold text-base-content">Grafo de Conocimiento</h2>
                    <p class="text-sm text-base-content/60">
                      Visualización de entidades y relaciones
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

                <%!-- Depth Control --%>
                <div class="flex items-center gap-3">
                  <label class="text-sm font-medium text-base-content/70">
                    Profundidad del grafo:
                  </label>
                  <div class="flex items-center gap-2">
                    <button
                      :for={depth_option <- [1, 2, 3, 4]}
                      phx-click="change-depth"
                      phx-value-depth={depth_option}
                      class={[
                        "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
                        if(@depth == depth_option,
                          do: "bg-[#0050AA] text-white",
                          else: "bg-base-200 text-base-content/70 hover:bg-base-300"
                        )
                      ]}
                    >
                      {depth_option}
                    </button>
                  </div>
                  <span class="text-xs text-base-content/50 ml-2">
                    (niveles de relación)
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

          <%!-- Product Details Card --%>
          <div :if={@product} class="mt-6 bg-base-100 border border-base-300 rounded-2xl p-6">
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
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_metadata_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_metadata_key(key), do: to_string(key)

  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value) when is_number(value), do: to_string(value)
  defp format_metadata_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_metadata_value(value) when is_map(value), do: Jason.encode!(value)
  defp format_metadata_value(nil), do: "-"
  defp format_metadata_value(value), do: inspect(value)

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
