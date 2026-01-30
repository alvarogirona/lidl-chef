import Graph from "graphology";
import Sigma from "sigma";
import ForceSupervisor from "graphology-layout-force/worker";

/**
 * Sigma.js Knowledge Graph Hook
 * 
 * Renders an interactive force-directed graph visualization
 * of product entities and their relationships using Sigma.js
 * for better performance with large graphs.
 */
const KnowledgeGraph = {
  mounted() {
    this.graphData = null
    this.graph = null
    this.renderer = null
    this.layout = null
    this.hiddenTypes = new Set()
    this.rootNodeId = null
    this.draggedNode = null
    this.isDragging = false
    this.allNodes = [] // Store all nodes for legend (not filtered)
    
    // Base color palette for known types
    this.baseColors = {
      "product": "#0050AA",
      "ingredient": "#22c55e",
      "allergen": "#ef4444",
      "brand": "#8b5cf6",
      "origin": "#f59e0b",
      "certification": "#06b6d4",
      "category": "#ec4899",
      "identifier": "#6b7280",
      "nutrient": "#84cc16",
      "producterpname": "#0050AA",
      "producttitle": "#0050AA",
      "wawiid": "#6b7280",
      "productline": "#ec4899",
      "receta": "#0050AA",
      "other": "#94a3b8"
    }
    
    // Dynamic color scale - will be populated with colors for all types
    this.colorScale = { ...this.baseColors }
    
    // Additional colors for dynamic types
    this.dynamicColorPalette = [
      "#3b82f6", "#10b981", "#f97316", "#a855f7", "#14b8a6",
      "#eab308", "#ef4444", "#6366f1", "#ec4899", "#06b6d4",
      "#84cc16", "#f43f5e", "#8b5cf6", "#22c55e", "#0ea5e9"
    ]
    this.dynamicColorIndex = 0
    
    this.typeLabels = {
      "product": "Producto",
      "ingredient": "Ingrediente",
      "allergen": "Alérgeno",
      "brand": "Marca",
      "origin": "Origen",
      "certification": "Certificación",
      "category": "Categoría",
      "identifier": "ID",
      "nutrient": "Nutriente",
      "producterpname": "Nombre ERP",
      "producttitle": "Título",
      "wawiid": "Wawi ID",
      "productline": "Línea",
      "other": "Otro"
    }
    
    // Handle data from server
    this.handleEvent("graph-data", (data) => {
      this.graphData = data
      this.renderGraph()
    })
    
    // Handle window resize
    this.resizeHandler = () => {
      if (this.renderer) {
        this.renderer.refresh()
      }
    }
    window.addEventListener("resize", this.resizeHandler)
    
    // Initial render if data is inline
    const inlineData = this.el.dataset.graphData
    if (inlineData) {
      try {
        this.graphData = JSON.parse(inlineData)
        this.renderGraph()
      } catch (e) {
        console.error("Failed to parse inline graph data:", e)
      }
    }
  },
  
  destroyed() {
    window.removeEventListener("resize", this.resizeHandler)
    this.cleanup()
  },
  
  cleanup() {
    if (this.layout) {
      this.layout.kill()
      this.layout = null
    }
    if (this.renderer) {
      this.renderer.kill()
      this.renderer = null
    }
    this.graph = null
  },
  
  renderGraph() {
    if (!this.graphData) return
    
    // Cleanup previous graph
    this.cleanup()
    
    // Clear container
    this.el.innerHTML = ""
    
    const { nodes, links } = this.graphData
    
    if (!nodes || nodes.length === 0) {
      this.renderEmptyState()
      return
    }
    
    // Identify the root/main node
    if (!this.rootNodeId) {
      const productNode = nodes.find(n => 
        n.type === "product" || 
        n.type === "producterpname" || 
        n.type === "producttitle"
      )
      this.rootNodeId = productNode ? productNode.id : nodes[0].id
    }
    
    // Filter nodes based on hidden types (but always show root node)
    let filteredNodes = nodes.filter(n => {
      const nodeType = (n.type || "other").toLowerCase()
      return n.id === this.rootNodeId || !this.hiddenTypes.has(nodeType)
    })
    
    let filteredNodeIds = new Set(filteredNodes.map(n => n.id))
    
    // Filter links to only include those between visible nodes
    let filteredLinks = links.filter(l => {
      const sourceId = typeof l.source === "object" ? l.source.id : l.source
      const targetId = typeof l.target === "object" ? l.target.id : l.target
      return filteredNodeIds.has(sourceId) && filteredNodeIds.has(targetId)
    })
    
    // Remove orphan nodes (nodes with no connections) except root node
    // Build a set of nodes that have at least one connection
    const connectedNodeIds = new Set()
    connectedNodeIds.add(this.rootNodeId) // Always keep root
    filteredLinks.forEach(l => {
      const sourceId = typeof l.source === "object" ? l.source.id : l.source
      const targetId = typeof l.target === "object" ? l.target.id : l.target
      connectedNodeIds.add(sourceId)
      connectedNodeIds.add(targetId)
    })
    
    // Filter out orphan nodes
    filteredNodes = filteredNodes.filter(n => connectedNodeIds.has(n.id))
    filteredNodeIds = new Set(filteredNodes.map(n => n.id))
    
    // Create the graph container and legend container
    const graphContainer = document.createElement("div")
    graphContainer.className = "relative w-full h-full"
    graphContainer.style.cssText = "position: relative; width: 100%; height: 100%;"
    
    const sigmaContainer = document.createElement("div")
    sigmaContainer.id = "sigma-container"
    sigmaContainer.style.cssText = "width: 100%; height: 100%;"
    
    graphContainer.appendChild(sigmaContainer)
    this.el.appendChild(graphContainer)
    
    // Create graphology graph
    this.graph = new Graph()
    
    // Build color scale for all types in the data (including dynamic ones)
    this.buildColorScale(nodes)
    
    // Add nodes with initial positions using a spiral layout for better distribution
    const nodeCount = filteredNodes.length
    const isVeryLargeGraph = nodeCount > 500
    const isLargeGraph = nodeCount > 100
    
    // Use spiral layout for large graphs - provides better initial distribution
    filteredNodes.forEach((node, i) => {
      let x, y
      
      if (node.id === this.rootNodeId) {
        x = 0
        y = 0
      } else if (isVeryLargeGraph) {
        // Spiral layout for very large graphs
        const spiralFactor = 15 // Controls how tight the spiral is
        const angle = i * 0.3 // Angle increment
        const radius = spiralFactor * Math.sqrt(i)
        x = radius * Math.cos(angle)
        y = radius * Math.sin(angle)
      } else {
        // Circle layout with randomness for smaller graphs
        const angle = (i * 2 * Math.PI) / nodeCount
        const baseRadius = Math.max(300, Math.sqrt(nodeCount) * 30)
        const radius = baseRadius + (Math.random() * 50)
        x = radius * Math.cos(angle)
        y = radius * Math.sin(angle)
      }
      
      const nodeType = (node.type || "other").toLowerCase()
      const isProduct = nodeType === "product" || nodeType === "producterpname" || nodeType === "producttitle" || nodeType === "receta"
      
      this.graph.addNode(node.id, {
        x: x,
        y: y,
        size: isProduct ? 15 : 8,
        color: this.getColorForType(nodeType),
        label: this.truncateLabel(node.name, 25),
        fullLabel: node.name,
        nodeType: nodeType,
        description: node.description
      })
    })
    
    // Add edges
    filteredLinks.forEach((link, i) => {
      const sourceId = typeof link.source === "object" ? link.source.id : link.source
      const targetId = typeof link.target === "object" ? link.target.id : link.target
      
      // Avoid duplicate edges
      const edgeKey = `${sourceId}-${targetId}`
      if (!this.graph.hasEdge(edgeKey) && !this.graph.hasEdge(`${targetId}-${sourceId}`)) {
        try {
          this.graph.addEdgeWithKey(edgeKey, sourceId, targetId, {
            size: Math.max(1, (link.strength || 5) / 5),
            color: "#cbd5e1",
            edgeType: link.type,
            label: link.type ? link.type.replace(/_/g, " ") : ""
          })
        } catch (e) {
          // Node might not exist if filtered
        }
      }
    })
    
    // Create the Sigma renderer with settings optimized for graph size
    this.renderer = new Sigma(this.graph, sigmaContainer, {
      minCameraRatio: 0.05,
      maxCameraRatio: 4,
      renderEdgeLabels: !isLargeGraph, // Disable edge labels for large graphs
      defaultEdgeType: "line", // Use simple lines for better performance
      // Higher threshold = fewer labels shown (less clutter)
      labelRenderedSizeThreshold: isVeryLargeGraph ? 20 : (isLargeGraph ? 12 : 8),
      labelFont: "Inter, system-ui, sans-serif",
      labelSize: isVeryLargeGraph ? 10 : 12,
      labelWeight: "500",
      edgeLabelFont: "Inter, system-ui, sans-serif",
      edgeLabelSize: 9,
      stagePadding: 50,
      // Reduce node size for very large graphs
      defaultNodeColor: "#94a3b8",
      labelDensity: isVeryLargeGraph ? 0.05 : (isLargeGraph ? 0.1 : 0.5),
      labelGridCellSize: isVeryLargeGraph ? 200 : (isLargeGraph ? 150 : 100),
    })
    
    // Create force layout with settings optimized for graph size
    // Different settings for small (<100), large (100-500), and very large (>500) graphs
    let layoutSettings
    if (isVeryLargeGraph) {
      layoutSettings = {
        attraction: 0.00001,
        repulsion: 1.5,
        gravity: 0.00001,
        inertia: 0.5,
        maxMove: 20
      }
    } else if (isLargeGraph) {
      layoutSettings = {
        attraction: 0.0001,
        repulsion: 0.8,
        gravity: 0.00005,
        inertia: 0.6,
        maxMove: 50
      }
    } else {
      layoutSettings = {
        attraction: 0.0005,
        repulsion: 0.15,
        gravity: 0.0001,
        inertia: 0.6,
        maxMove: 200
      }
    }
    
    this.layout = new ForceSupervisor(this.graph, {
      isNodeFixed: (_, attr) => attr.highlighted,
      settings: layoutSettings
    })
    this.layout.start()
    
    // Setup drag and drop
    this.setupDragAndDrop()
    
    // Setup node click handler
    this.renderer.on("clickNode", ({ node }) => {
      const attrs = this.graph.getNodeAttributes(node)
      this.pushEvent("node-clicked", { 
        id: node, 
        name: attrs.fullLabel || attrs.label, 
        type: attrs.nodeType 
      })
    })
    
    // Setup hover highlighting
    this.setupHoverHighlighting()
    
    // Add legend using ALL nodes (not filtered) so hidden types remain visible
    this.addLegend(graphContainer, nodes)
  },
  
  // Build color scale dynamically for all types in the data
  buildColorScale(nodes) {
    const allTypes = new Set()
    nodes.forEach(n => {
      const nodeType = (n.type || "other").toLowerCase()
      allTypes.add(nodeType)
    })
    
    // Assign colors to any types not in base colors
    allTypes.forEach(type => {
      if (!this.colorScale[type]) {
        this.colorScale[type] = this.dynamicColorPalette[this.dynamicColorIndex % this.dynamicColorPalette.length]
        this.dynamicColorIndex++
      }
    })
  },
  
  // Get color for a type, with fallback
  getColorForType(type) {
    const normalizedType = (type || "other").toLowerCase()
    return this.colorScale[normalizedType] || this.colorScale["other"] || "#94a3b8"
  },
  
  setupDragAndDrop() {
    // On mouse down on a node - enable drag mode
    this.renderer.on("downNode", (e) => {
      this.isDragging = true
      this.draggedNode = e.node
      this.graph.setNodeAttribute(this.draggedNode, "highlighted", true)
      if (!this.renderer.getCustomBBox()) {
        this.renderer.setCustomBBox(this.renderer.getBBox())
      }
    })
    
    // On mouse move, update dragged node position
    this.renderer.on("moveBody", ({ event }) => {
      if (!this.isDragging || !this.draggedNode) return
      
      // Get new position of node
      const pos = this.renderer.viewportToGraph(event)
      
      this.graph.setNodeAttribute(this.draggedNode, "x", pos.x)
      this.graph.setNodeAttribute(this.draggedNode, "y", pos.y)
      
      // Prevent sigma from moving camera
      event.preventSigmaDefault()
      event.original.preventDefault()
      event.original.stopPropagation()
    })
    
    // On mouse up, reset dragging mode
    const handleUp = () => {
      if (this.draggedNode) {
        this.graph.removeNodeAttribute(this.draggedNode, "highlighted")
      }
      this.isDragging = false
      this.draggedNode = null
    }
    
    this.renderer.on("upNode", handleUp)
    this.renderer.on("upStage", handleUp)
  },
  
  setupHoverHighlighting() {
    let hoveredNode = null
    let hoveredNeighbors = new Set()
    
    this.renderer.on("enterNode", ({ node }) => {
      hoveredNode = node
      hoveredNeighbors = new Set(this.graph.neighbors(node))
      
      // Update node reducers to dim non-connected nodes
      this.renderer.setSetting("nodeReducer", (n, data) => {
        if (n === hoveredNode || hoveredNeighbors.has(n)) {
          return { ...data, zIndex: 1 }
        }
        return { ...data, color: "#e2e8f0", zIndex: 0 }
      })
      
      // Update edge reducers to dim non-connected edges
      this.renderer.setSetting("edgeReducer", (edge, data) => {
        const source = this.graph.source(edge)
        const target = this.graph.target(edge)
        if (source === hoveredNode || target === hoveredNode) {
          return { ...data, color: "#64748b", zIndex: 1 }
        }
        return { ...data, color: "#f1f5f9", zIndex: 0 }
      })
    })
    
    this.renderer.on("leaveNode", () => {
      hoveredNode = null
      hoveredNeighbors.clear()
      
      // Reset reducers
      this.renderer.setSetting("nodeReducer", null)
      this.renderer.setSetting("edgeReducer", null)
    })
  },
  
  addLegend(container, nodes) {
    // Calculate type counts from ALL node data (use lowercase for consistency)
    const typeCounts = {}
    nodes.forEach(n => {
      const nodeType = (n.type || "other").toLowerCase()
      typeCounts[nodeType] = (typeCounts[nodeType] || 0) + 1
    })
    
    // Sort types: put main types first, then alphabetically
    const priorityTypes = ["receta", "product", "producttitle", "producterpname", "ingredient", "allergen", "category"]
    const existingTypes = Object.keys(typeCounts).sort((a, b) => {
      const aIdx = priorityTypes.indexOf(a)
      const bIdx = priorityTypes.indexOf(b)
      if (aIdx !== -1 && bIdx !== -1) return aIdx - bIdx
      if (aIdx !== -1) return -1
      if (bIdx !== -1) return 1
      return a.localeCompare(b)
    })
    
    // Create legend container
    const legend = document.createElement("div")
    legend.className = "absolute top-4 right-4 bg-white border border-gray-200 rounded-lg shadow-sm p-3 z-10"
    legend.style.cssText = "max-height: calc(100% - 32px); overflow-y: auto;"
    
    existingTypes.forEach(type => {
      const isHidden = this.hiddenTypes.has(type)
      
      const item = document.createElement("div")
      item.className = "flex items-center gap-2 py-1.5 px-2 rounded cursor-pointer hover:bg-gray-50 transition-colors"
      item.style.cssText = isHidden ? "opacity: 0.5;" : ""
      
      const circle = document.createElement("div")
      circle.className = "w-3 h-3 rounded-full flex-shrink-0"
      circle.style.backgroundColor = this.getColorForType(type)
      if (isHidden) {
        circle.style.opacity = "0.4"
      }
      
      const label = document.createElement("span")
      label.className = "text-xs text-gray-600"
      label.style.cssText = isHidden ? "text-decoration: line-through;" : ""
      // Capitalize first letter for display
      const displayName = this.typeLabels[type] || (type.charAt(0).toUpperCase() + type.slice(1))
      label.textContent = `${displayName} (${typeCounts[type]})`
      
      item.appendChild(circle)
      item.appendChild(label)
      
      // Click handler to toggle type visibility
      item.addEventListener("click", (e) => {
        e.stopPropagation()
        this.toggleType(type)
      })
      
      legend.appendChild(item)
    })
    
    container.appendChild(legend)
  },
  
  toggleType(type) {
    const normalizedType = type.toLowerCase()
    if (this.hiddenTypes.has(normalizedType)) {
      this.hiddenTypes.delete(normalizedType)
    } else {
      this.hiddenTypes.add(normalizedType)
    }
    this.renderGraph()
  },
  
  renderEmptyState() {
    this.el.innerHTML = `
      <div class="flex items-center justify-center h-full text-base-content/50">
        <div class="text-center">
          <svg class="w-16 h-16 mx-auto mb-4 opacity-50" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/>
          </svg>
          <p>No hay datos del grafo disponibles</p>
        </div>
      </div>
    `
  },
  
  truncateLabel(text, maxLength) {
    if (!text) return ""
    return text.length > maxLength ? text.substring(0, maxLength - 3) + "..." : text
  }
}

export { KnowledgeGraph }
