import * as d3 from "d3"

const KnowledgeGraph = {
  mounted() {
    this.graphData = null
    this.simulation = null
    this.hiddenTypes = new Set()
    this.rootNodeId = null
    this.canvas = null
    this.context = null
    this.transform = d3.zoomIdentity
    this.hoveredNode = null
    this.tooltip = null
    
    this.handleEvent("graph-data", (data) => {
      this.graphData = data
      this.renderGraph()
    })
    
    this.resizeHandler = () => this.renderGraph()
    window.addEventListener("resize", this.resizeHandler)
    
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
    if (this.tooltip && this.tooltip.parentNode) {
      this.tooltip.parentNode.removeChild(this.tooltip)
    }
  },
  
  renderGraph() {
    if (!this.graphData) return
    
    d3.select(this.el).selectAll("*").remove()
    
    const { nodes, links } = this.graphData
    
    if (!nodes || nodes.length === 0) {
      this.renderEmptyState()
      return
    }
    
    if (!this.rootNodeId) {
      const productNode = nodes.find(n => 
        n.type === "product" || 
        n.type === "producterpname" || 
        n.type === "producttitle"
      )
      this.rootNodeId = productNode ? productNode.id : nodes[0].id
    }
    
    const filteredNodes = nodes.filter(n => 
      n.id === this.rootNodeId || !this.hiddenTypes.has(n.type)
    )
    
    const filteredNodeIds = new Set(filteredNodes.map(n => n.id))
    
    const filteredLinks = links.filter(l => {
      const sourceId = typeof l.source === "object" ? l.source.id : l.source
      const targetId = typeof l.target === "object" ? l.target.id : l.target
      return filteredNodeIds.has(sourceId) && filteredNodeIds.has(targetId)
    })
    
    const container = this.el
    const width = container.clientWidth || 800
    const height = container.clientHeight || 600
    
    this.canvas = d3.select(container)
      .append("canvas")
      .attr("width", width)
      .attr("height", height)
      .style("width", "100%")
      .style("height", "100%")
      .style("cursor", "grab")
      .node()
    
    this.context = this.canvas.getContext("2d")
    
    const colorScale = d3.scaleOrdinal()
      .domain(["product", "ingredient", "allergen", "brand", "origin", "certification", "category", "identifier", "nutrient", "other"])
      .range(["#0050AA", "#22c55e", "#ef4444", "#8b5cf6", "#f59e0b", "#06b6d4", "#ec4899", "#6b7280", "#84cc16", "#94a3b8"])
    
    this.simulation = d3.forceSimulation(filteredNodes)
      .force("link", d3.forceLink(filteredLinks)
        .id(d => d.id)
        .distance(100)
        .strength(0.5))
      .force("charge", d3.forceManyBody()
        .strength(-300))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collision", d3.forceCollide().radius(40))
    
    const linkMap = new Map()
    filteredLinks.forEach(l => {
      const sourceId = typeof l.source === "object" ? l.source.id : l.source
      const targetId = typeof l.target === "object" ? l.target.id : l.target
      const key = `${sourceId}-${targetId}`
      const reverseKey = `${targetId}-${sourceId}`
      
      if (linkMap.has(reverseKey)) {
        linkMap.get(reverseKey).bidirectional = true
        l.bidirectional = true
        l.curveDirection = -1
      } else {
        linkMap.set(key, l)
        l.curveDirection = 1
      }
    })
    
    filteredNodes.forEach(node => {
      node.radius = node.type === "product" ? 20 : 12
      node.color = colorScale(node.type || "other")
    })
    
    this.createTooltip()
    
    this.setupCanvasInteractions(filteredNodes, filteredLinks, width, height)
    
    this.simulation.on("tick", () => {
      this.drawCanvas(filteredNodes, filteredLinks, width, height)
    })
    
    this.addLegend(container, colorScale, width, nodes)
  },
  
  drawCanvas(nodes, links, width, height) {
    const ctx = this.context
    const transform = this.transform
    
    ctx.save()
    ctx.clearRect(0, 0, width, height)
    
    ctx.translate(transform.x, transform.y)
    ctx.scale(transform.k, transform.k)
    
    links.forEach(link => {
      const sourceId = typeof link.source === "object" ? link.source.id : link.source
      const targetId = typeof link.target === "object" ? link.target.id : link.target
      
      let opacity = 0.6
      if (this.hoveredNode) {
        opacity = (sourceId === this.hoveredNode.id || targetId === this.hoveredNode.id) ? 1 : 0.1
      }
      
      ctx.strokeStyle = `rgba(203, 213, 225, ${opacity})`
      ctx.lineWidth = Math.max(1, (link.strength || 5) / 3)
      ctx.beginPath()
      
      if (link.bidirectional) {
        const dx = link.target.x - link.source.x
        const dy = link.target.y - link.source.y
        const dr = Math.sqrt(dx * dx + dy * dy)
        
        if (dr > 0) {
          const offsetX = -dy / dr
          const offsetY = dx / dr
          const offset = 30 * link.curveDirection
          
          const cx = (link.source.x + link.target.x) / 2 + offsetX * offset
          const cy = (link.source.y + link.target.y) / 2 + offsetY * offset
          
          ctx.moveTo(link.source.x, link.source.y)
          ctx.quadraticCurveTo(cx, cy, link.target.x, link.target.y)
        }
      } else {
        ctx.moveTo(link.source.x, link.source.y)
        ctx.lineTo(link.target.x, link.target.y)
      }
      
      ctx.stroke()
      
      this.drawArrow(ctx, link, opacity)
      
      if (transform.k > 1.5 && link.type) {
        this.drawLinkLabel(ctx, link, opacity)
      }
    })
    
    nodes.forEach(node => {
      let opacity = 1
      if (this.hoveredNode) {
        const isHovered = node.id === this.hoveredNode.id
        const isConnected = this.isConnected(node, this.hoveredNode, links)
        opacity = (isHovered || isConnected) ? 1 : 0.3
      }
      
      ctx.beginPath()
      ctx.arc(node.x, node.y, node.radius, 0, 2 * Math.PI)
      ctx.fillStyle = node.color
      ctx.globalAlpha = opacity
      ctx.fill()
      
      ctx.strokeStyle = "#fff"
      ctx.lineWidth = 2
      ctx.stroke()
      ctx.globalAlpha = 1
      
      if (opacity > 0.3) {
        this.drawNodeLabel(ctx, node, opacity)
      }
    })
    
    ctx.restore()
  },
  
  drawArrow(ctx, link, opacity) {
    const dx = link.target.x - link.source.x
    const dy = link.target.y - link.source.y
    const angle = Math.atan2(dy, dx)
    
    const targetNode = link.target
    const arrowDistance = targetNode.radius || 12
    const arrowX = link.target.x - Math.cos(angle) * arrowDistance
    const arrowY = link.target.y - Math.sin(angle) * arrowDistance
    
    const arrowSize = 6
    ctx.save()
    ctx.translate(arrowX, arrowY)
    ctx.rotate(angle)
    
    ctx.beginPath()
    ctx.moveTo(0, 0)
    ctx.lineTo(-arrowSize, -arrowSize / 2)
    ctx.lineTo(-arrowSize, arrowSize / 2)
    ctx.closePath()
    
    ctx.fillStyle = `rgba(153, 153, 153, ${opacity})`
    ctx.fill()
    ctx.restore()
  },
  
  drawLinkLabel(ctx, link, opacity) {
    const label = link.type ? link.type.replace(/_/g, " ") : ""
    if (!label) return
    
    let x, y
    if (link.bidirectional) {
      const dx = link.target.x - link.source.x
      const dy = link.target.y - link.source.y
      const dr = Math.sqrt(dx * dx + dy * dy)
      
      if (dr > 0) {
        const offsetX = -dy / dr
        const offsetY = dx / dr
        const offset = 30 * link.curveDirection
        
        x = (link.source.x + link.target.x) / 2 + offsetX * offset
        y = (link.source.y + link.target.y) / 2 + offsetY * offset
      } else {
        x = (link.source.x + link.target.x) / 2
        y = (link.source.y + link.target.y) / 2
      }
    } else {
      x = (link.source.x + link.target.x) / 2
      y = (link.source.y + link.target.y) / 2
    }
    
    ctx.font = "9px Inter, system-ui, sans-serif"
    ctx.fillStyle = `rgba(100, 116, 139, ${opacity})`
    ctx.textAlign = "center"
    ctx.textBaseline = "bottom"
    ctx.fillText(label, x, y - 2)
  },
  
  drawNodeLabel(ctx, node, opacity) {
    const label = this.truncateLabel(node.name, 25)
    const dx = node.type === "product" ? 25 : 17
    const fontSize = node.type === "product" ? 13 : 11
    const fontWeight = node.type === "product" ? "bold" : "normal"
    
    ctx.font = `${fontWeight} ${fontSize}px Inter, system-ui, sans-serif`
    ctx.fillStyle = `rgba(30, 41, 59, ${opacity})`
    ctx.textAlign = "left"
    ctx.textBaseline = "middle"
    ctx.fillText(label, node.x + dx, node.y)
  },
  
  isConnected(node1, node2, links) {
    return links.some(l => {
      const sourceId = typeof l.source === "object" ? l.source.id : l.source
      const targetId = typeof l.target === "object" ? l.target.id : l.target
      return (sourceId === node1.id && targetId === node2.id) || 
             (targetId === node1.id && sourceId === node2.id)
    })
  },
  
  setupCanvasInteractions(nodes, links, width, height) {
    const canvas = d3.select(this.canvas)
    
    const zoom = d3.zoom()
      .scaleExtent([0.1, 4])
      .on("zoom", (event) => {
        this.transform = event.transform
        this.drawCanvas(nodes, links, width, height)
      })
    
    canvas.call(zoom)
    
    canvas.on("mousemove", (event) => {
      const [mx, my] = d3.pointer(event)
      const [transformedX, transformedY] = this.transform.invert([mx, my])
      
      const hoveredNode = nodes.find(node => {
        const dx = node.x - transformedX
        const dy = node.y - transformedY
        const distance = Math.sqrt(dx * dx + dy * dy)
        return distance <= node.radius
      })
      
      if (hoveredNode !== this.hoveredNode) {
        this.hoveredNode = hoveredNode
        this.drawCanvas(nodes, links, width, height)
        
        if (hoveredNode) {
          this.showTooltip(event, hoveredNode)
          this.canvas.style.cursor = "pointer"
        } else {
          this.hideTooltip()
          this.canvas.style.cursor = this.isDragging ? "grabbing" : "grab"
        }
      } else if (hoveredNode) {
        this.updateTooltipPosition(event)
      }
    })
    
    canvas.on("click", (event) => {
      if (this.hoveredNode) {
        event.stopPropagation()
        this.pushEvent("node-clicked", { 
          id: this.hoveredNode.id, 
          name: this.hoveredNode.name, 
          type: this.hoveredNode.type 
        })
      }
    })
    
    canvas.on("mouseleave", () => {
      this.hoveredNode = null
      this.hideTooltip()
      this.drawCanvas(nodes, links, width, height)
    })
    
    const drag = d3.drag()
      .subject((event) => {
        const [mx, my] = d3.pointer(event)
        const [transformedX, transformedY] = this.transform.invert([mx, my])
        
        return nodes.find(node => {
          const dx = node.x - transformedX
          const dy = node.y - transformedY
          const distance = Math.sqrt(dx * dx + dy * dy)
          return distance <= node.radius
        })
      })
      .on("start", (event) => {
        if (!event.active) this.simulation.alphaTarget(0.3).restart()
        event.subject.fx = event.subject.x
        event.subject.fy = event.subject.y
        this.canvas.style.cursor = "grabbing"
        this.isDragging = true
      })
      .on("drag", (event) => {
        const [transformedX, transformedY] = this.transform.invert([event.x, event.y])
        event.subject.fx = transformedX
        event.subject.fy = transformedY
      })
      .on("end", (event) => {
        if (!event.active) this.simulation.alphaTarget(0)
        event.subject.fx = null
        event.subject.fy = null
        this.canvas.style.cursor = "grab"
        this.isDragging = false
      })
    
    canvas.call(drag)
  },
  
  createTooltip() {
    this.tooltip = document.createElement("div")
    this.tooltip.className = "absolute hidden bg-white border border-gray-200 rounded-lg shadow-lg p-2 text-sm pointer-events-none z-50"
    this.tooltip.style.cssText = "max-width: 200px;"
    document.body.appendChild(this.tooltip)
  },
  
  showTooltip(event, node) {
    if (!this.tooltip) return
    
    const description = node.description ? `<div class="text-xs text-gray-500 mt-1">${node.description}</div>` : ""
    this.tooltip.innerHTML = `
      <div class="font-semibold text-gray-900">${node.name}</div>
      <div class="text-xs text-gray-500">Type: ${node.type || "unknown"}</div>
      ${description}
    `
    this.updateTooltipPosition(event)
    this.tooltip.classList.remove("hidden")
  },
  
  updateTooltipPosition(event) {
    if (!this.tooltip) return
    this.tooltip.style.left = `${event.clientX + 12}px`
    this.tooltip.style.top = `${event.clientY + 12}px`
  },
  
  hideTooltip() {
    if (this.tooltip) {
      this.tooltip.classList.add("hidden")
    }
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
  
  addLegend(container, colorScale, width, nodes) {
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
      "producterpname": "Nombre ERP",
      "producttitle": "Título",
      "wawiid": "Wawi ID",
      "productline": "Línea",
      "other": "Otro"
    }
    
    const typeCounts = {}
    nodes.forEach(n => {
      const type = n.type || "other"
      typeCounts[type] = (typeCounts[type] || 0) + 1
    })
    
    const existingTypes = Object.keys(typeCounts).sort()
    
    const svg = d3.select(container)
      .append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .style("position", "absolute")
      .style("top", "0")
      .style("left", "0")
      .style("pointer-events", "none")
    
    const legend = svg.append("g")
      .attr("class", "legend")
      .attr("transform", `translate(${width - 160}, 20)`)
      .style("pointer-events", "all")
    
    legend.append("rect")
      .attr("x", -10)
      .attr("y", -10)
      .attr("width", 150)
      .attr("height", existingTypes.length * 24 + 20)
      .attr("fill", "white")
      .attr("stroke", "#e2e8f0")
      .attr("rx", 8)
      .attr("opacity", 0.95)
    
    const items = legend.selectAll(".legend-item")
      .data(existingTypes)
      .join("g")
      .attr("class", "legend-item")
      .attr("transform", (d, i) => `translate(0, ${i * 24})`)
      .style("cursor", "pointer")
      .on("click", (event, type) => {
        event.stopPropagation()
        this.toggleType(type)
      })
    
    items.on("mouseenter", function() {
      d3.select(this).select("rect.hover-bg")
        .attr("opacity", 0.1)
    })
    .on("mouseleave", function() {
      d3.select(this).select("rect.hover-bg")
        .attr("opacity", 0)
    })
    
    items.append("rect")
      .attr("class", "hover-bg")
      .attr("x", -5)
      .attr("y", -10)
      .attr("width", 140)
      .attr("height", 20)
      .attr("fill", "#0050AA")
      .attr("rx", 4)
      .attr("opacity", 0)
    
    items.append("circle")
      .attr("r", 6)
      .attr("fill", d => colorScale(d))
      .attr("opacity", d => this.hiddenTypes.has(d) ? 0.3 : 1)
    
    items.append("text")
      .attr("x", 12)
      .attr("y", 4)
      .attr("font-size", "11px")
      .attr("fill", "#475569")
      .attr("opacity", d => this.hiddenTypes.has(d) ? 0.5 : 1)
      .attr("text-decoration", d => this.hiddenTypes.has(d) ? "line-through" : "none")
      .text(d => {
        const label = typeLabels[d] || d
        return `${label} (${typeCounts[d]})`
      })
  },
  
  toggleType(type) {
    if (this.hiddenTypes.has(type)) {
      this.hiddenTypes.delete(type)
    } else {
      this.hiddenTypes.add(type)
    }
    this.renderGraph()
  },
  
  truncateLabel(text, maxLength) {
    if (!text) return ""
    return text.length > maxLength ? text.substring(0, maxLength - 3) + "..." : text
  }
}

export { KnowledgeGraph }
