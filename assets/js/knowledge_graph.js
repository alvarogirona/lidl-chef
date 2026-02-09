import Graph from "graphology";
import Sigma from "sigma";

/**
 * Sigma.js Knowledge Graph Hook
 * 
 * Renders an interactive graph visualization of product entities 
 * and their relationships using Sigma.js with a static radial layout
 * optimized for large graphs.
 */
const KnowledgeGraph = {
  mounted() {
    this.graphData = null
    this.graph = null
    this.renderer = null
    this.hiddenTypes = new Set()
    this.rootNodeId = null
    this.hoveredNode = null
    this.hoveredEdge = null
    this.hoveredNeighbors = new Set()
    this.edgeTooltip = null
    
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
      "título": "#0050AA",
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
    if (this.renderer) {
      this.renderer.kill()
      this.renderer = null
    }
    if (this.edgeTooltip && this.edgeTooltip.parentNode) {
      this.edgeTooltip.parentNode.removeChild(this.edgeTooltip)
      this.edgeTooltip = null
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
      const productNode = nodes.find(n => {
        const t = (n.type || "").toLowerCase()
        return t === "product" || t === "producterpname" || t === "producttitle"
      })
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
    const connectedNodeIds = new Set()
    connectedNodeIds.add(this.rootNodeId)
    filteredLinks.forEach(l => {
      const sourceId = typeof l.source === "object" ? l.source.id : l.source
      const targetId = typeof l.target === "object" ? l.target.id : l.target
      connectedNodeIds.add(sourceId)
      connectedNodeIds.add(targetId)
    })
    
    filteredNodes = filteredNodes.filter(n => connectedNodeIds.has(n.id))
    filteredNodeIds = new Set(filteredNodes.map(n => n.id))
    
    // Create the graph container
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
    
    // Build color scale for all types
    this.buildColorScale(nodes)
    
    // Calculate positions using force-directed layout
    const positions = this.calculateRadialLayout(filteredNodes, filteredLinks)
    
    // Add nodes with calculated positions
    const nodeCount = filteredNodes.length
    const isVeryLargeGraph = nodeCount > 500
    const isLargeGraph = nodeCount > 100
    
    console.log(`Adding ${nodeCount} nodes to graph`)
    
    filteredNodes.forEach((node) => {
      const nodeType = (node.type || "other").toLowerCase()
      const isMainType = nodeType === "product" || nodeType === "producterpname" || 
                         nodeType === "producttitle" || nodeType === "receta" || nodeType === "título"
      
      const pos = positions.get(node.id) || { x: 0, y: 0 }
      
      // Adjust node size based on graph size
      let nodeSize = isMainType ? 12 : 6
      if (isVeryLargeGraph) {
        nodeSize = isMainType ? 8 : 4
      } else if (isLargeGraph) {
        nodeSize = isMainType ? 10 : 5
      }
      
      this.graph.addNode(node.id, {
        x: pos.x,
        y: pos.y,
        size: nodeSize,
        color: this.getColorForType(nodeType),
        label: node.name || "",
        nodeType: nodeType,
        description: node.description
      })
    })
    
    console.log(`Graph now has ${this.graph.order} nodes`)
    
    // Add edges
    filteredLinks.forEach((link) => {
      const sourceId = typeof link.source === "object" ? link.source.id : link.source
      const targetId = typeof link.target === "object" ? link.target.id : link.target
      
      const edgeKey = `${sourceId}-${targetId}`
      if (!this.graph.hasEdge(edgeKey) && !this.graph.hasEdge(`${targetId}-${sourceId}`)) {
        try {
          // Format label from edge type (e.g., "has_ingredient" -> "has ingredient")
          const edgeLabel = link.type ? link.type.replace(/_/g, " ") : ""
          
          this.graph.addEdgeWithKey(edgeKey, sourceId, targetId, {
            size: 0.5,
            color: "#e2e8f0",
            edgeType: link.type,
            label: edgeLabel,
            metadata: link.metadata || {}
          })
        } catch (e) {
          // Node might not exist
        }
      }
    })
    
    // Create the Sigma renderer
    // Enable edge labels for smaller graphs only (performance consideration)
    const showEdgeLabels = nodeCount < 200
    
    this.renderer = new Sigma(this.graph, sigmaContainer, {
      minCameraRatio: 0.02,
      maxCameraRatio: 5,
      renderEdgeLabels: showEdgeLabels,
      defaultEdgeType: "line",
      labelRenderedSizeThreshold: isVeryLargeGraph ? 15 : (isLargeGraph ? 10 : 6),
      labelFont: "Inter, system-ui, sans-serif",
      labelSize: isVeryLargeGraph ? 10 : 12,
      labelWeight: "500",
      labelColor: { color: "#1e293b" },
      edgeLabelFont: "Inter, system-ui, sans-serif",
      edgeLabelSize: 9,
      edgeLabelColor: { color: "#64748b" },
      stagePadding: 50,
      labelDensity: isVeryLargeGraph ? 0.03 : (isLargeGraph ? 0.07 : 0.3),
      labelGridCellSize: isVeryLargeGraph ? 250 : (isLargeGraph ? 180 : 120),
      zIndex: true,
    })
    
    // Setup interactions
    this.setupInteractions()
    
    // Add legend
    this.addLegend(graphContainer, nodes)
    
    // Fit the camera to show all nodes
    this.renderer.getCamera().animatedReset({ duration: 300 })
  },
  
  /**
   * Calculate positions using a force-directed layout
   * Similar to D3.js force simulation for better node distribution
   */
  calculateRadialLayout(nodes, links) {
    const positions = new Map()
    const nodeCount = nodes.length
    
    console.log(`Force layout: processing ${nodeCount} nodes and ${links.length} links`)
    
    // Initialize random positions around origin
    nodes.forEach(node => {
      positions.set(node.id, {
        x: (Math.random() - 0.5) * 200,
        y: (Math.random() - 0.5) * 200,
        vx: 0,
        vy: 0
      })
    })
    
    // Build adjacency map
    const adjacency = new Map()
    nodes.forEach(n => adjacency.set(n.id, new Set()))
    
    links.forEach(l => {
      const sourceId = typeof l.source === "object" ? l.source.id : l.source
      const targetId = typeof l.target === "object" ? l.target.id : l.target
      if (adjacency.has(sourceId)) adjacency.get(sourceId).add(targetId)
      if (adjacency.has(targetId)) adjacency.get(targetId).add(sourceId)
    })
    
    // Node radius function
    const getNodeRadius = (node) => {
      const type = (node.type || "other").toLowerCase()
      const mainTypes = new Set(["receta", "product", "producttitle", "producterpname", "título"])
      return mainTypes.has(type) ? 25 : 15
    }
    
    // Force simulation parameters - adjusted for better performance on large graphs
    const iterations = nodeCount > 200 ? 150 : 250
    const linkDistance = 100
    const linkStrength = 0.3
    const chargeStrength = -400
    const centerStrength = 0.05
    const collisionPadding = 5
    
    // Run simulation
    for (let i = 0; i < iterations; i++) {
      const alpha = 1 - (i / iterations) // Decay over time
      
      // Apply centering force
      let centerX = 0, centerY = 0
      nodes.forEach(node => {
        const pos = positions.get(node.id)
        centerX += pos.x
        centerY += pos.y
      })
      centerX /= nodeCount
      centerY /= nodeCount
      
      nodes.forEach(node => {
        const pos = positions.get(node.id)
        pos.vx -= (pos.x - 0) * centerStrength * alpha
        pos.vy -= (pos.y - 0) * centerStrength * alpha
      })
      
      // Apply link forces (spring forces)
      links.forEach(link => {
        const sourceId = typeof link.source === "object" ? link.source.id : link.source
        const targetId = typeof link.target === "object" ? link.target.id : link.target
        
        const source = positions.get(sourceId)
        const target = positions.get(targetId)
        
        if (!source || !target) return
        
        const dx = target.x - source.x
        const dy = target.y - source.y
        const distance = Math.sqrt(dx * dx + dy * dy) || 1
        
        const force = (distance - linkDistance) * linkStrength * alpha
        const fx = (dx / distance) * force
        const fy = (dy / distance) * force
        
        source.vx += fx
        source.vy += fy
        target.vx -= fx
        target.vy -= fy
      })
      
      // Apply charge forces (repulsion between all nodes)
      // Use quadratic complexity only for smaller graphs
      if (nodeCount < 300) {
        for (let j = 0; j < nodes.length; j++) {
          const nodeA = nodes[j]
          const posA = positions.get(nodeA.id)
          
          for (let k = j + 1; k < nodes.length; k++) {
            const nodeB = nodes[k]
            const posB = positions.get(nodeB.id)
            
            const dx = posB.x - posA.x
            const dy = posB.y - posA.y
            const distanceSq = dx * dx + dy * dy
            
            if (distanceSq === 0 || distanceSq < 0.01) {
              // Add small random displacement if nodes are at exact same position
              posB.x += (Math.random() - 0.5) * 1
              posB.y += (Math.random() - 0.5) * 1
              continue
            }
            
            // Clamp distance to avoid extreme forces
            const clampedDistSq = Math.max(distanceSq, 1)
            const distance = Math.sqrt(clampedDistSq)
            const force = (chargeStrength * alpha) / clampedDistSq
            const fx = (dx / distance) * force
            const fy = (dy / distance) * force
            
            posA.vx -= fx
            posA.vy -= fy
            posB.vx += fx
            posB.vy += fy
          }
        }
        
        // Apply collision forces
        for (let j = 0; j < nodes.length; j++) {
          const nodeA = nodes[j]
          const posA = positions.get(nodeA.id)
          const radiusA = getNodeRadius(nodeA) + collisionPadding
          
          for (let k = j + 1; k < nodes.length; k++) {
            const nodeB = nodes[k]
            const posB = positions.get(nodeB.id)
            const radiusB = getNodeRadius(nodeB) + collisionPadding
            
            const dx = posB.x - posA.x
            const dy = posB.y - posA.y
            const distance = Math.sqrt(dx * dx + dy * dy)
            const minDistance = radiusA + radiusB
            
            if (distance < minDistance && distance > 0) {
              const force = (minDistance - distance) / distance * 0.5
              const fx = dx * force
              const fy = dy * force
              
              posA.x -= fx
              posA.y -= fy
              posB.x += fx
              posB.y += fy
            }
          }
        }
      }
      
      // Update positions with velocity
      nodes.forEach(node => {
        const pos = positions.get(node.id)
        
        // Clamp velocity to prevent explosion
        const maxVelocity = 50
        pos.vx = Math.max(-maxVelocity, Math.min(maxVelocity, pos.vx))
        pos.vy = Math.max(-maxVelocity, Math.min(maxVelocity, pos.vy))
        
        pos.x += pos.vx
        pos.y += pos.vy
        
        // Check for NaN
        if (isNaN(pos.x) || isNaN(pos.y)) {
          pos.x = (Math.random() - 0.5) * 100
          pos.y = (Math.random() - 0.5) * 100
          pos.vx = 0
          pos.vy = 0
        }
        
        // Apply damping
        pos.vx *= 0.8
        pos.vy *= 0.8
      })
    }
    
    // Log sample positions for debugging
    const sampleNode = nodes[0]
    if (sampleNode) {
      const samplePos = positions.get(sampleNode.id)
      console.log(`Sample position for node ${sampleNode.id}:`, samplePos)
    }
    
    return positions
  },
  
  // Build color scale dynamically for all types in the data
  buildColorScale(nodes) {
    const allTypes = new Set()
    nodes.forEach(n => {
      const nodeType = (n.type || "other").toLowerCase()
      allTypes.add(nodeType)
    })
    
    allTypes.forEach(type => {
      if (!this.colorScale[type]) {
        this.colorScale[type] = this.dynamicColorPalette[this.dynamicColorIndex % this.dynamicColorPalette.length]
        this.dynamicColorIndex++
      }
    })
  },
  
  // Get color for a type
  getColorForType(type) {
    const normalizedType = (type || "other").toLowerCase()
    return this.colorScale[normalizedType] || this.colorScale["other"] || "#94a3b8"
  },
  
  setupInteractions() {
    // Create tooltip element for edge metadata
    this.edgeTooltip = document.createElement("div")
    this.edgeTooltip.className = "fixed z-50 bg-white border border-gray-200 rounded-lg shadow-lg p-3 text-sm pointer-events-none hidden"
    this.edgeTooltip.style.cssText = "max-width: 280px; transition: opacity 0.15s ease;"
    document.body.appendChild(this.edgeTooltip)
    
    // Node click handler
    this.renderer.on("clickNode", ({ node }) => {
      const attrs = this.graph.getNodeAttributes(node)
      this.pushEvent("node-clicked", { 
        id: node, 
        name: attrs.label, 
        type: attrs.nodeType 
      })
    })
    
    // Hover highlighting using reducers (like in example3)
    this.renderer.on("enterNode", ({ node }) => {
      this.hoveredNode = node
      this.hoveredEdge = null
      this.hoveredNeighbors = new Set(this.graph.neighbors(node))
      this.hideEdgeTooltip()
      this.renderer.refresh({ skipIndexation: true })
    })
    
    this.renderer.on("leaveNode", () => {
      this.hoveredNode = null
      this.hoveredNeighbors.clear()
      this.renderer.refresh({ skipIndexation: true })
    })
    
    // Edge hover for tooltip
    this.renderer.on("enterEdge", ({ edge, event }) => {
      if (this.hoveredNode) return // Don't show tooltip when hovering a node
      
      this.hoveredEdge = edge
      const attrs = this.graph.getEdgeAttributes(edge)
      const source = this.graph.source(edge)
      const target = this.graph.target(edge)
      const sourceAttrs = this.graph.getNodeAttributes(source)
      const targetAttrs = this.graph.getNodeAttributes(target)
      
      this.showEdgeTooltip(event, {
        type: attrs.edgeType,
        label: attrs.label,
        metadata: attrs.metadata,
        sourceName: sourceAttrs.label,
        targetName: targetAttrs.label
      })
      
      this.renderer.refresh({ skipIndexation: true })
    })
    
    this.renderer.on("leaveEdge", () => {
      this.hoveredEdge = null
      this.hideEdgeTooltip()
      this.renderer.refresh({ skipIndexation: true })
    })
    
    // Update tooltip position on mouse move
    this.el.addEventListener("mousemove", (e) => {
      if (this.hoveredEdge && this.edgeTooltip && !this.edgeTooltip.classList.contains("hidden")) {
        this.edgeTooltip.style.left = `${e.clientX + 12}px`
        this.edgeTooltip.style.top = `${e.clientY + 12}px`
      }
    })
    
    // Set up reducers for hover effects
    this.renderer.setSetting("nodeReducer", (node, data) => {
      if (this.hoveredNode) {
        if (node === this.hoveredNode) {
          return { ...data, highlighted: true, zIndex: 2 }
        }
        if (this.hoveredNeighbors.has(node)) {
          return { ...data, zIndex: 1 }
        }
        // Dim non-connected nodes
        return { ...data, color: "#e2e8f0", label: "", zIndex: 0 }
      }
      return data
    })
    
    this.renderer.setSetting("edgeReducer", (edge, data) => {
      // Highlight hovered edge
      if (this.hoveredEdge === edge) {
        return { ...data, color: "#0050AA", size: 2, zIndex: 2, forceLabel: true }
      }
      
      if (this.hoveredNode) {
        const source = this.graph.source(edge)
        const target = this.graph.target(edge)
        if (source === this.hoveredNode || target === this.hoveredNode) {
          return { ...data, color: "#64748b", size: 1.5, zIndex: 1, forceLabel: true }
        }
        return { ...data, hidden: true }
      }
      return data
    })
  },
  
  showEdgeTooltip(event, edgeData) {
    if (!this.edgeTooltip) return
    
    const { type, label, metadata, sourceName, targetName } = edgeData
    
    // Build tooltip content
    let html = `
      <div class="font-semibold text-gray-900 mb-2 flex items-center gap-2">
        <span class="w-2 h-2 rounded-full bg-blue-500"></span>
        ${label || type || "Relación"}
      </div>
      <div class="text-xs text-gray-500 mb-2">
        <span class="text-gray-700">${sourceName}</span>
        <span class="mx-1">→</span>
        <span class="text-gray-700">${targetName}</span>
      </div>
    `
    
    // Add metadata if present
    if (metadata && Object.keys(metadata).length > 0) {
      html += `<div class="border-t border-gray-100 pt-2 mt-2 space-y-1">`
      for (const [key, value] of Object.entries(metadata)) {
        if (value !== null && value !== undefined && value !== "") {
          const formattedKey = key.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase())
          const formattedValue = typeof value === "object" ? JSON.stringify(value) : value
          html += `
            <div class="flex justify-between gap-4">
              <span class="text-gray-500">${formattedKey}:</span>
              <span class="text-gray-900 font-medium text-right">${formattedValue}</span>
            </div>
          `
        }
      }
      html += `</div>`
    }
    
    this.edgeTooltip.innerHTML = html
    this.edgeTooltip.style.left = `${event.clientX + 12}px`
    this.edgeTooltip.style.top = `${event.clientY + 12}px`
    this.edgeTooltip.classList.remove("hidden")
  },
  
  hideEdgeTooltip() {
    if (this.edgeTooltip) {
      this.edgeTooltip.classList.add("hidden")
    }
  },
  
  addLegend(container, nodes) {
    // Calculate type counts from ALL node data
    const typeCounts = {}
    nodes.forEach(n => {
      const nodeType = (n.type || "other").toLowerCase()
      typeCounts[nodeType] = (typeCounts[nodeType] || 0) + 1
    })
    
    // Sort types
    const priorityTypes = ["receta", "product", "producttitle", "producterpname", "título", "ingredient", "allergen", "category"]
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
      const displayName = this.typeLabels[type] || (type.charAt(0).toUpperCase() + type.slice(1))
      label.textContent = `${displayName} (${typeCounts[type]})`
      
      item.appendChild(circle)
      item.appendChild(label)
      
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
  }
}

export { KnowledgeGraph }
