defmodule LidlChefWeb.GraphDetailLive do
  use LidlChefWeb, :live_view

  alias Arcana.Graph.GraphStore
  alias LidlChef.Repo

  import Ecto.Query

  @impl true
  def mount(%{"entity_id" => entity_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:entity_id, entity_id)
     |> assign(:entity, nil)
     |> assign(:graph_data, nil)
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:depth, 2)
     |> assign(:selected_node, nil)
     |> assign(:selected_node_relationships, [])
     |> load_entity_and_graph()}
  end

  defp load_entity_and_graph(socket) do
    entity_id = socket.assigns.entity_id
    depth = socket.assigns.depth

    # Fetch the entity by ID
    case GraphStore.get_entity(entity_id, repo: Repo) do
      {:ok, entity} ->
        # Build the graph data for this entity with specified depth
        graph_data = build_graph_data(entity, depth)

        socket
        |> assign(:entity, entity)
        |> assign(:graph_data, graph_data)
        |> assign(:loading, false)

      {:error, _} ->
        socket
        |> assign(:loading, false)
        |> assign(:error, "Entidad no encontrada con ID: #{entity_id}")
    end
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
          strength: rel.strength || 5
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
              </div>
            </div>
          </div>
        </div>

        <%!-- Graph Section with Detail Card --%>
        <div :if={@entity && !@loading} class="max-w-6xl mx-auto px-4 sm:px-6 pb-12">
          <div class="relative">
            <%!-- Selected Node Detail Card --%>
            <div
              :if={@selected_node}
              class="absolute top-20 left-6 z-10 bg-white border border-base-300 rounded-xl shadow-lg max-w-sm w-80 animate-fade-in"
            >
              <div class="p-4">
                <div class="flex items-start justify-between mb-3">
                  <div class="flex items-center gap-2 flex-1 min-w-0">
                    <h3 class="font-semibold text-base-content truncate flex-1">
                      {@selected_node.name}
                    </h3>
                    <.link
                      navigate={~p"/graph/#{@selected_node.id}"}
                      class="flex-shrink-0 p-1.5 hover:bg-base-200 rounded-lg transition-colors"
                      title="Ver detalles"
                    >
                      <.icon name="hero-arrow-right" class="w-5 h-5 text-[#0050AA]" />
                    </.link>
                  </div>
                  <button
                    phx-click="close-detail"
                    class="flex-shrink-0 ml-2 p-1 hover:bg-base-200 rounded-lg transition-colors"
                  >
                    <.icon name="hero-x-mark" class="w-5 h-5 text-base-content/60" />
                  </button>
                </div>

                <span class="inline-flex items-center px-2 py-1 rounded-md text-xs font-medium bg-[#0050AA]/10 text-[#0050AA] mb-3">
                  {@selected_node.type}
                </span>

                <div :if={@selected_node_relationships != []} class="space-y-2">
                  <p class="text-xs font-medium text-base-content/70 uppercase tracking-wide">
                    Relaciones
                  </p>
                  <div class="space-y-1.5 max-h-48 overflow-y-auto">
                    <div
                      :for={rel <- @selected_node_relationships}
                      class="flex items-start gap-2 text-sm p-2 bg-base-50 rounded-lg hover:bg-base-100 transition-colors"
                    >
                      <.icon
                        name={if rel.direction == :outgoing, do: "hero-arrow-right-mini", else: "hero-arrow-left-mini"}
                        class="w-4 h-4 text-base-content/40 mt-0.5 flex-shrink-0"
                      />
                      <div class="flex-1 min-w-0">
                        <p class="text-xs text-base-content/60 font-medium">
                          {rel.type |> String.replace("_", " ")}
                        </p>
                        <p class="text-base-content truncate">
                          {rel.entity.name}
                        </p>
                        <p class="text-xs text-base-content/50">
                          {rel.entity.type}
                        </p>
                      </div>
                    </div>
                  </div>
                </div>

                <div :if={@selected_node_relationships == []} class="text-sm text-base-content/60">
                  No hay relaciones disponibles
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
