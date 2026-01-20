import * as d3 from "d3"

/**
 * D3.js Knowledge Graph Hook
 * 
 * Renders an interactive force-directed graph visualization
 * of product entities and their relationships.
 */
const KnowledgeGraph = {
  mounted() {
    this.graphData = null
    this.simulation = null
    
    // Handle data from server
    this.handleEvent("graph-data", (data) => {
      this.graphData = data
      this.renderGraph()
    })
    
    // Handle window resize
    this.resizeHandler = () => this.renderGraph()
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
    if (this.simulation) {
      this.simulation.stop()
    }
  },
  
  renderGraph() {
    if (!this.graphData) return
    
    // Clear previous graph
    d3.select(this.el).selectAll("*").remove()
    
    const { nodes, links } = this.graphData
    
    if (!nodes || nodes.length === 0) {
      this.renderEmptyState()
      return
    }
    
    const container = this.el
    const width = container.clientWidth || 800
    const height = container.clientHeight || 600
    
    // Create SVG
    const svg = d3.select(container)
      .append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("viewBox", [0, 0, width, height])
      .attr("class", "knowledge-graph-svg")
    
    // Add zoom behavior
    const g = svg.append("g")
    
    const zoom = d3.zoom()
      .scaleExtent([0.1, 4])
      .on("zoom", (event) => {
        g.attr("transform", event.transform)
      })
    
    svg.call(zoom)
    
    // Define arrow markers for directed edges
    svg.append("defs").selectAll("marker")
      .data(["arrow"])
      .join("marker")
      .attr("id", d => d)
      .attr("viewBox", "0 -5 10 10")
      .attr("refX", 20)
      .attr("refY", 0)
      .attr("markerWidth", 6)
      .attr("markerHeight", 6)
      .attr("orient", "auto")
      .append("path")
      .attr("fill", "#999")
      .attr("d", "M0,-5L10,0L0,5")
    
    // Color scale for node types
    const colorScale = d3.scaleOrdinal()
      .domain(["product", "ingredient", "allergen", "brand", "origin", "certification", "category", "identifier", "nutrient", "other"])
      .range(["#0050AA", "#22c55e", "#ef4444", "#8b5cf6", "#f59e0b", "#06b6d4", "#ec4899", "#6b7280", "#84cc16", "#94a3b8"])
    
    // Create force simulation
    this.simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links)
        .id(d => d.id)
        .distance(100)
        .strength(0.5))
      .force("charge", d3.forceManyBody()
        .strength(-300))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collision", d3.forceCollide().radius(40))
    
    // Create links
    const link = g.append("g")
      .attr("class", "links")
      .selectAll("g")
      .data(links)
      .join("g")
    
    const linkLine = link.append("line")
      .attr("stroke", "#cbd5e1")
      .attr("stroke-width", d => Math.max(1, (d.strength || 5) / 3))
      .attr("stroke-opacity", 0.6)
      .attr("marker-end", "url(#arrow)")
    
    // Link labels
    const linkLabel = link.append("text")
      .attr("class", "link-label")
      .attr("font-size", "9px")
      .attr("fill", "#64748b")
      .attr("text-anchor", "middle")
      .attr("dy", -5)
      .text(d => d.type ? d.type.replace(/_/g, " ") : "")
    
    // Create nodes
    const node = g.append("g")
      .attr("class", "nodes")
      .selectAll("g")
      .data(nodes)
      .join("g")
      .attr("class", "node")
      .call(this.drag(this.simulation))
    
    // Node circles
    node.append("circle")
      .attr("r", d => d.type === "product" ? 20 : 12)
      .attr("fill", d => colorScale(d.type || "other"))
      .attr("stroke", "#fff")
      .attr("stroke-width", 2)
      .attr("cursor", "pointer")
    
    // Node labels
    node.append("text")
      .attr("dx", d => d.type === "product" ? 25 : 17)
      .attr("dy", 4)
      .attr("font-size", d => d.type === "product" ? "13px" : "11px")
      .attr("font-weight", d => d.type === "product" ? "bold" : "normal")
      .attr("fill", "#1e293b")
      .text(d => this.truncateLabel(d.name, 25))
    
    // Tooltips
    node.append("title")
      .text(d => `${d.name}\nType: ${d.type || "unknown"}${d.description ? "\n" + d.description : ""}`)
    
    // Node click handler
    node.on("click", (event, d) => {
      event.stopPropagation()
      this.pushEvent("node-clicked", { id: d.id, name: d.name, type: d.type })
    })
    
    // Highlight on hover
    node.on("mouseenter", (event, d) => {
      // Highlight connected nodes and links
      const connectedNodeIds = new Set()
      connectedNodeIds.add(d.id)
      
      links.forEach(l => {
        const sourceId = typeof l.source === "object" ? l.source.id : l.source
        const targetId = typeof l.target === "object" ? l.target.id : l.target
        if (sourceId === d.id) connectedNodeIds.add(targetId)
        if (targetId === d.id) connectedNodeIds.add(sourceId)
      })
      
      node.attr("opacity", n => connectedNodeIds.has(n.id) ? 1 : 0.3)
      link.attr("opacity", l => {
        const sourceId = typeof l.source === "object" ? l.source.id : l.source
        const targetId = typeof l.target === "object" ? l.target.id : l.target
        return sourceId === d.id || targetId === d.id ? 1 : 0.1
      })
    })
    
    node.on("mouseleave", () => {
      node.attr("opacity", 1)
      link.attr("opacity", 1)
    })
    
    // Update positions on tick
    this.simulation.on("tick", () => {
      linkLine
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y)
      
      linkLabel
        .attr("x", d => (d.source.x + d.target.x) / 2)
        .attr("y", d => (d.source.y + d.target.y) / 2)
      
      node.attr("transform", d => `translate(${d.x},${d.y})`)
    })
    
    // Add legend
    this.addLegend(svg, colorScale, width)
  },
  
  renderEmptyState() {
    const container = this.el
    d3.select(container)
      .append("div")
      .attr("class", "flex items-center justify-center h-full text-base-content/50")
      .html(`
        <div class="text-center">
          <svg class="w-16 h-16 mx-auto mb-4 opacity-50" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/>
          </svg>
          <p>No hay datos del grafo disponibles</p>
        </div>
      `)
  },
  
  addLegend(svg, colorScale, width) {
    const legend = svg.append("g")
      .attr("class", "legend")
      .attr("transform", `translate(${width - 140}, 20)`)
    
    const types = colorScale.domain()
    const typeLabels = {
      "product": "Producto",
      "ingredient": "Ingrediente",
      "allergen": "Alérgeno",
      "brand": "Marca",
      "origin": "Origen",
      "certification": "Certificación",
      "category": "Categoría",
      "identifier": "ID",
      "nutrient": "Nutriente",
      "other": "Otro"
    }
    
    // Background
    legend.append("rect")
      .attr("x", -10)
      .attr("y", -10)
      .attr("width", 130)
      .attr("height", types.length * 20 + 20)
      .attr("fill", "white")
      .attr("stroke", "#e2e8f0")
      .attr("rx", 8)
      .attr("opacity", 0.95)
    
    const items = legend.selectAll(".legend-item")
      .data(types)
      .join("g")
      .attr("class", "legend-item")
      .attr("transform", (d, i) => `translate(0, ${i * 20})`)
    
    items.append("circle")
      .attr("r", 6)
      .attr("fill", d => colorScale(d))
    
    items.append("text")
      .attr("x", 12)
      .attr("y", 4)
      .attr("font-size", "11px")
      .attr("fill", "#475569")
      .text(d => typeLabels[d] || d)
  },
  
  drag(simulation) {
    function dragstarted(event) {
      if (!event.active) simulation.alphaTarget(0.3).restart()
      event.subject.fx = event.subject.x
      event.subject.fy = event.subject.y
    }
    
    function dragged(event) {
      event.subject.fx = event.x
      event.subject.fy = event.y
    }
    
    function dragended(event) {
      if (!event.active) simulation.alphaTarget(0)
      event.subject.fx = null
      event.subject.fy = null
    }
    
    return d3.drag()
      .on("start", dragstarted)
      .on("drag", dragged)
      .on("end", dragended)
  },
  
  truncateLabel(text, maxLength) {
    if (!text) return ""
    return text.length > maxLength ? text.substring(0, maxLength - 3) + "..." : text
  }
}

export { KnowledgeGraph }
