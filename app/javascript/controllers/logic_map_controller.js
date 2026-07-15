import { Controller } from "@hotwired/stimulus"

// The "zoom out" flow map for answer-branching. Reads the LIVE deck from the
// survey-editor controller (serialize() → cards with cid + logic), builds a
// layered DAG of card nodes + end-screen terminals, and draws it as hand-rolled
// inline SVG with cubic-Bézier connectors — no external graph library (the
// importmap has no bundler and the app's only precedent is hand-authored SVG).
// Read-only: pan (drag) + zoom (wheel) via the SVG viewBox, and click a card to
// jump to it in the editor. Editable drag-to-branch lands in a later phase.
const SVG = "http://www.w3.org/2000/svg"
const NODE_W = 200
const NODE_H = 70
const COL_GAP = 120
const ROW_GAP = 34
const MARGIN = 48

export default class extends Controller {
  static targets = ["overlay", "svg", "empty"]
  static values = { ends: { type: Array, default: [] }, editable: { type: Boolean, default: false } }
  static ROUTABLE = ["multiple_choice", "yes_no"]

  connect() {
    // The editor content sits inside a `position: fixed` wrapper (fullscreen
    // layout), which forms a stacking context the app's top nav paints over.
    // Portal the overlay to <body> so the "zoom out" map covers everything;
    // its close button now lives outside the controller scope, so bind it here.
    if (this.hasOverlayTarget) {
      this._overlay = this.overlayTarget
      document.body.appendChild(this._overlay)
      this._svg = this._overlay.querySelector(".logic-map-svg")
      this._empty = this._overlay.querySelector(".logic-map-empty")
      this._overlay.querySelector(".logic-map-close")?.addEventListener("click", () => this.close())
    }
  }

  open(event) {
    if (event) event.preventDefault()
    if (!this._overlay) return
    this._vb = null // re-fit to the deck each time the map is opened
    this._render()
    this._overlay.classList.remove("hidden")
    this._prevOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"
    this._onKey = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this._onKey)
  }

  close() {
    this._overlay?.classList.add("hidden")
    document.body.style.overflow = this._prevOverflow || ""
    if (this._onKey) document.removeEventListener("keydown", this._onKey)
  }

  disconnect() {
    if (this._onKey) document.removeEventListener("keydown", this._onKey)
    this._overlay?.remove()
  }

  // ── graph model ────────────────────────────────────────────────────────────

  _editor() {
    const el = document.querySelector("[data-survey-editor-url-value]")
    return el ? this.application.getControllerForElementAndIdentifier(el, "survey-editor") : null
  }

  _buildGraph() {
    const cards = this._editor()?.serialize()?.cards || []
    const cidOf = new Map(cards.map(c => [c.cid, c]))
    const endsById = new Map((this.endsValue || []).map(e => [e.id, e]))

    const nodes = cards.map((c, i) => ({
      key: c.cid, kind: "card", type: c.type, num: i + 1,
      text: (c.text || "").trim(), index: i,
      options: Array.isArray(c.options) ? c.options : []
    }))
    const nodeByKey = new Map(nodes.map(n => [n.key, n]))

    const endNodes = new Map()
    const ensureEnd = (id) => {
      const key = `end:${id}`
      if (!endNodes.has(key)) {
        const e = endsById.get(id)
        endNodes.set(key, { key, kind: "end", endId: id, text: (e && e.title) || (id === "default" ? "Thank-you" : id) })
      }
      return key
    }

    const edges = []
    cards.forEach((c, i) => {
      const logic = c.logic
      let covered = false // a default (card/end) replaces the linear fall-through
      if (logic && typeof logic === "object") {
        (Array.isArray(logic.routes) ? logic.routes : []).forEach(r => {
          const label = (r && r.match && r.match.value) || ""
          const to = r && r.to
          if (!to) return
          if (to.card && nodeByKey.has(to.card)) edges.push({ from: c.cid, to: to.card, label, kind: "route", opt: label })
          else if (to.card) edges.push({ from: c.cid, to: null, label, kind: "dangling", opt: label })
          else if (to.end) edges.push({ from: c.cid, to: ensureEnd(to.end), label, kind: "route", opt: label })
        })
        const d = logic.default
        if (d && (d.card || d.end)) {
          covered = true
          if (d.card && nodeByKey.has(d.card)) edges.push({ from: c.cid, to: d.card, label: "otherwise", kind: "default", opt: "__default__" })
          else if (d.card) edges.push({ from: c.cid, to: null, label: "otherwise", kind: "dangling", opt: "__default__" })
          else if (d.end) edges.push({ from: c.cid, to: ensureEnd(d.end), label: "otherwise", kind: "default", opt: "__default__" })
        }
      }
      if (!covered) {
        if (i + 1 < cards.length) edges.push({ from: c.cid, to: cards[i + 1].cid, label: "", kind: "linear" })
        else edges.push({ from: c.cid, to: ensureEnd("default"), label: "", kind: "linear" })
      }
    })

    const allNodes = [...nodes, ...endNodes.values()]
    return { nodes, allNodes, endNodes, edges, nodeByKey }
  }

  // Longest-path layering from the entry (card 0), cycle-safe. End nodes sit one
  // column past the deepest card. Unreached cards are pushed to their own column.
  _layout(graph) {
    const { nodes, endNodes, edges } = graph
    const adj = new Map(nodes.map(n => [n.key, []]))
    edges.forEach(e => { if (e.to && adj.has(e.from) && adj.has(e.to)) adj.get(e.from).push(e.to) })

    const layer = new Map()
    if (nodes.length) layer.set(nodes[0].key, 0)
    // Relax N times (bounded so weaving cycles can't loop forever).
    for (let pass = 0; pass < nodes.length + 1; pass++) {
      edges.forEach(e => {
        if (!e.to || !adj.has(e.to)) return
        if (!layer.has(e.from)) return
        const cand = layer.get(e.from) + 1
        if (!layer.has(e.to) || cand > layer.get(e.to)) layer.set(e.to, cand)
      })
    }
    let maxLayer = 0
    nodes.forEach(n => { if (layer.has(n.key)) maxLayer = Math.max(maxLayer, layer.get(n.key)) })
    // Unreached cards: park them in the column after the reachable graph.
    nodes.forEach(n => { if (!layer.has(n.key)) { maxLayer += 1; layer.set(n.key, maxLayer); n.unreachable = true } })
    // End nodes: final column.
    const endLayer = maxLayer + 1
    endNodes.forEach(n => layer.set(n.key, endLayer))

    // Order within each layer by original index (cards) / insertion (ends).
    const byLayer = new Map()
    graph.allNodes.forEach(n => {
      const L = layer.get(n.key) ?? 0
      if (!byLayer.has(L)) byLayer.set(L, [])
      byLayer.get(L).push(n)
    })
    let maxRows = 1
    byLayer.forEach(list => {
      list.sort((a, b) => (a.index ?? 999) - (b.index ?? 999))
      list.forEach((n, k) => {
        n.x = MARGIN + (layer.get(n.key)) * (NODE_W + COL_GAP)
        n.y = MARGIN + k * (NODE_H + ROW_GAP)
      })
      maxRows = Math.max(maxRows, list.length)
    })
    const width  = MARGIN * 2 + endLayer * (NODE_W + COL_GAP) + NODE_W
    const height = MARGIN * 2 + (maxRows - 1) * (NODE_H + ROW_GAP) + NODE_H
    return { width, height }
  }

  // ── render ───────────────────────────────────────────────────────────────

  _render() {
    const graph = this._buildGraph()
    const svg = this._svg
    while (svg.firstChild) svg.removeChild(svg.firstChild)

    if (!graph.nodes.length) {
      if (this._empty) this._empty.classList.remove("hidden")
      return
    }
    if (this._empty) this._empty.classList.add("hidden")

    const { width, height } = this._layout(graph)
    // Keep the current pan/zoom across edit re-renders; re-fit only on open.
    if (!this._vb) this._vb = { x: 0, y: 0, w: width, h: height }
    svg.setAttribute("viewBox", `${this._vb.x} ${this._vb.y} ${this._vb.w} ${this._vb.h}`)
    svg.appendChild(this._defs())

    const posByKey = new Map(graph.allNodes.map(n => [n.key, n]))
    const eLayer = this._g()
    graph.edges.forEach(e => { const p = this._edgePath(e, posByKey); if (p) eLayer.appendChild(p) })
    svg.appendChild(eLayer)

    const nLayer = this._g()
    graph.allNodes.forEach(n => nLayer.appendChild(n.kind === "end" ? this._endNode(n) : this._cardNode(n)))
    svg.appendChild(nLayer)

    this._setupPanZoom()
  }

  _defs() {
    const defs = document.createElementNS(SVG, "defs")
    const mk = (id, color) => {
      const m = document.createElementNS(SVG, "marker")
      m.setAttribute("id", id); m.setAttribute("markerWidth", "8"); m.setAttribute("markerHeight", "8")
      m.setAttribute("refX", "7"); m.setAttribute("refY", "3"); m.setAttribute("orient", "auto"); m.setAttribute("markerUnits", "userSpaceOnUse")
      const path = document.createElementNS(SVG, "path")
      path.setAttribute("d", "M0,0 L7,3 L0,6 Z"); path.setAttribute("fill", color)
      m.appendChild(path); return m
    }
    defs.appendChild(mk("arrow-route", "#01EACB"))
    defs.appendChild(mk("arrow-faint", "rgba(255,255,255,0.35)"))
    defs.appendChild(mk("arrow-danger", "#F87171"))
    return defs
  }

  _edgePath(e, posByKey) {
    const from = posByKey.get(e.from)
    if (!from) return null
    const sx = from.x + NODE_W, sy = from.y + NODE_H / 2
    let tx, ty
    if (e.to && posByKey.has(e.to)) {
      const to = posByKey.get(e.to); tx = to.x; ty = to.y + NODE_H / 2
    } else {
      tx = sx + 90; ty = sy // dangling: a short stub
    }
    const style = {
      route:   { stroke: "#01EACB", dash: "", marker: "arrow-route",  w: 2 },
      default: { stroke: "rgba(255,255,255,0.5)", dash: "5 5", marker: "arrow-faint", w: 1.6 },
      linear:  { stroke: "rgba(255,255,255,0.22)", dash: "4 6", marker: "arrow-faint", w: 1.4 },
      dangling:{ stroke: "#F87171", dash: "3 4", marker: "arrow-danger", w: 1.8 }
    }[e.kind] || { stroke: "rgba(255,255,255,0.3)", dash: "", marker: "arrow-faint", w: 1.4 }

    const g = this._g()
    const dx = Math.max(40, Math.abs(tx - sx))
    const d = `M ${sx} ${sy} C ${sx + dx * 0.5} ${sy}, ${tx - dx * 0.5} ${ty}, ${tx} ${ty}`

    // When editing, a fat invisible hit-path makes the connector easy to click
    // to remove (reverts that answer to the default flow).
    const deletable = this.editableValue && e.opt
    if (deletable) {
      const hit = document.createElementNS(SVG, "path")
      hit.setAttribute("d", d); hit.setAttribute("fill", "none")
      hit.setAttribute("stroke", "transparent"); hit.setAttribute("stroke-width", "14")
      hit.style.cursor = "pointer"
      const title = document.createElementNS(SVG, "title"); title.textContent = "Click to remove this route"
      hit.appendChild(title)
      hit.addEventListener("click", () => this._deleteEdge(e))
      g.appendChild(hit)
    }

    const path = document.createElementNS(SVG, "path")
    path.setAttribute("d", d)
    path.setAttribute("fill", "none")
    path.setAttribute("stroke", style.stroke)
    path.setAttribute("stroke-width", style.w)
    if (style.dash) path.setAttribute("stroke-dasharray", style.dash)
    path.setAttribute("marker-end", `url(#${style.marker})`)
    path.style.pointerEvents = "none"
    g.appendChild(path)

    if (e.label) {
      // Place the label partway ALONG its own edge (not at the shared source),
      // so several routes leaving one card don't stack their labels.
      const t = document.createElementNS(SVG, "text")
      t.setAttribute("x", sx + (tx - sx) * 0.42)
      t.setAttribute("y", sy + (ty - sy) * 0.42 - 6)
      t.setAttribute("text-anchor", "middle")
      t.setAttribute("fill", e.kind === "dangling" ? "#F87171" : (e.kind === "route" ? "#01EACB" : "rgba(255,255,255,0.5)"))
      t.setAttribute("font-size", "11"); t.setAttribute("font-family", "'ABeeZee', sans-serif")
      t.textContent = this._trunc(e.label, 18)
      g.appendChild(t)
    }
    return g
  }

  _cardNode(n) {
    const g = this._g()
    g.setAttribute("transform", `translate(${n.x} ${n.y})`)
    g.setAttribute("style", "cursor:pointer")
    g.dataset.nodeKey = n.key
    g.dataset.nodeKind = "card"
    g.addEventListener("click", () => this._jumpTo(n.key))

    const rect = document.createElementNS(SVG, "rect")
    rect.setAttribute("width", NODE_W); rect.setAttribute("height", NODE_H); rect.setAttribute("rx", 14)
    rect.setAttribute("fill", n.unreachable ? "rgba(255,255,255,0.03)" : "rgba(255,255,255,0.07)")
    rect.setAttribute("stroke", n.unreachable ? "rgba(248,113,113,0.55)" : "rgba(255,255,255,0.16)")
    if (n.unreachable) rect.setAttribute("stroke-dasharray", "4 4")
    rect.setAttribute("stroke-width", "1.5")
    g.appendChild(rect)

    g.appendChild(this._text(14, 22, this._trunc(this._badge(n.type), 20), { size: 10, fill: "rgba(1,234,203,0.85)", spacing: "0.06em" }))
    g.appendChild(this._text(14, 44, this._trunc(n.text || "Untitled", 24), { size: 13, fill: "#fff" }))
    g.appendChild(this._text(14, 60, n.unreachable ? "unreachable" : `Card ${n.num}`, { size: 10, fill: n.unreachable ? "#F87171" : "rgba(255,255,255,0.4)" }))

    // Editable: a draggable output port per answer (+ an "otherwise" default),
    // on the right edge. Drag a port onto another node to route that answer.
    if (this.editableValue && this.constructor.ROUTABLE.includes(n.type)) {
      const ports = [...n.options.map(o => ({ opt: o, label: o })), { opt: "__default__", label: "otherwise" }]
      const gap = Math.min(16, (NODE_H - 8) / Math.max(1, ports.length - 1))
      const startY = Math.max(12, (NODE_H - (ports.length - 1) * gap) / 2)
      ports.forEach((port, k) => {
        const py = startY + k * gap
        const dot = document.createElementNS(SVG, "circle")
        dot.setAttribute("cx", NODE_W); dot.setAttribute("cy", py); dot.setAttribute("r", 5)
        dot.setAttribute("fill", "#615BF5"); dot.setAttribute("stroke", "#fff"); dot.setAttribute("stroke-width", "1")
        dot.style.cursor = "crosshair"
        const title = document.createElementNS(SVG, "title")
        title.textContent = `Drag to route "${port.label}"`
        dot.appendChild(title)
        dot.addEventListener("pointerdown", (ev) => { ev.stopPropagation(); this._beginConnect(n.key, port.opt, n.x + NODE_W, n.y + py, ev) })
        g.appendChild(dot)
      })
    }
    return g
  }

  _endNode(n) {
    const g = this._g()
    g.setAttribute("transform", `translate(${n.x} ${n.y})`)
    g.dataset.nodeKey = n.key
    g.dataset.nodeKind = "end"
    const rect = document.createElementNS(SVG, "rect")
    rect.setAttribute("width", NODE_W); rect.setAttribute("height", NODE_H); rect.setAttribute("rx", NODE_H / 2)
    rect.setAttribute("fill", "rgba(1,234,203,0.12)"); rect.setAttribute("stroke", "#01EACB"); rect.setAttribute("stroke-width", "1.5")
    g.appendChild(rect)
    g.appendChild(this._text(20, 30, "FINISH", { size: 10, fill: "rgba(1,234,203,0.85)", spacing: "0.08em" }))
    g.appendChild(this._text(20, 48, "🏁 " + this._trunc(n.text, 20), { size: 13, fill: "#fff" }))
    return g
  }

  _text(x, y, str, opts = {}) {
    const t = document.createElementNS(SVG, "text")
    t.setAttribute("x", x); t.setAttribute("y", y)
    t.setAttribute("font-size", opts.size || 12); t.setAttribute("fill", opts.fill || "#fff")
    t.setAttribute("font-family", "'ABeeZee', sans-serif")
    if (opts.spacing) t.setAttribute("letter-spacing", opts.spacing)
    t.textContent = str
    return t
  }

  _badge(type) { return String(type || "").replace(/_/g, " ").toUpperCase() }
  _trunc(s, n) { s = String(s || ""); return s.length > n ? s.slice(0, n - 1) + "…" : s }
  _g() { return document.createElementNS(SVG, "g") }

  _jumpTo(cid) {
    this.close()
    const el = document.querySelector(`.survey-card-wrap[data-card-cid="${cid}"]`)
    if (el) {
      el.scrollIntoView({ behavior: "smooth", block: "center" })
      el.classList.add("card-flash")
      setTimeout(() => el.classList.remove("card-flash"), 1200)
    }
  }

  // ── pan / zoom via the SVG viewBox ─────────────────────────────────────────

  _setupPanZoom() {
    const svg = this._svg
    const apply = () => svg.setAttribute("viewBox", `${this._vb.x} ${this._vb.y} ${this._vb.w} ${this._vb.h}`)

    let dragging = false, lastX = 0, lastY = 0
    svg.onpointerdown = (e) => {
      if (this._connect) return // a port connection is in progress — don't pan
      dragging = true; lastX = e.clientX; lastY = e.clientY; svg.setPointerCapture(e.pointerId); svg.style.cursor = "grabbing"
    }
    svg.onpointermove = (e) => {
      if (this._connect) { const p = this._clientToUser(e.clientX, e.clientY); this._updateConnect(p.x, p.y); return }
      if (!dragging) return
      const r = svg.getBoundingClientRect()
      this._vb.x -= (e.clientX - lastX) * (this._vb.w / r.width)
      this._vb.y -= (e.clientY - lastY) * (this._vb.h / r.height)
      lastX = e.clientX; lastY = e.clientY; apply()
    }
    const stop = (e) => {
      if (this._connect) { this._endConnect(e.clientX, e.clientY); return }
      dragging = false; svg.style.cursor = "grab"; try { svg.releasePointerCapture(e.pointerId) } catch (_) {}
    }
    svg.onpointerup = stop
    svg.onpointerleave = (e) => { if (!this._connect) stop(e) }
    svg.onwheel = (e) => {
      e.preventDefault()
      const r = svg.getBoundingClientRect()
      const mx = this._vb.x + (e.clientX - r.left) / r.width * this._vb.w
      const my = this._vb.y + (e.clientY - r.top) / r.height * this._vb.h
      const factor = e.deltaY > 0 ? 1.12 : 0.89
      const nw = Math.min(Math.max(this._vb.w * factor, 200), 12000)
      const nh = nw * (this._vb.h / this._vb.w)
      this._vb.x = mx - (mx - this._vb.x) * (nw / this._vb.w)
      this._vb.y = my - (my - this._vb.y) * (nh / this._vb.h)
      this._vb.w = nw; this._vb.h = nh; apply()
    }
    svg.style.cursor = "grab"
  }

  // ── editing: drag a port to connect, click a line to remove ────────────────

  _beginConnect(fromKey, opt, sx, sy, ev) {
    this._connect = { from: fromKey, opt, sx, sy }
    try { this._svg.setPointerCapture(ev.pointerId) } catch (_) {}
    const temp = document.createElementNS(SVG, "path")
    temp.setAttribute("fill", "none"); temp.setAttribute("stroke", "#615BF5")
    temp.setAttribute("stroke-width", "2"); temp.setAttribute("stroke-dasharray", "5 4")
    temp.setAttribute("pointer-events", "none")
    this._temp = temp; this._svg.appendChild(temp)
    this._updateConnect(sx, sy)
  }

  _updateConnect(ux, uy) {
    const c = this._connect
    if (!c || !this._temp) return
    const dx = Math.max(30, Math.abs(ux - c.sx))
    this._temp.setAttribute("d", `M ${c.sx} ${c.sy} C ${c.sx + dx * 0.5} ${c.sy}, ${ux - dx * 0.5} ${uy}, ${ux} ${uy}`)
  }

  _endConnect(clientX, clientY) {
    const c = this._connect
    this._connect = null
    if (this._temp) { this._temp.remove(); this._temp = null }
    if (!c) return
    const el = document.elementFromPoint(clientX, clientY)
    const grp = el && el.closest ? el.closest("[data-node-key]") : null
    if (grp) {
      const key = grp.dataset.nodeKey
      if (grp.dataset.nodeKind === "end") this._setRoute(c.from, c.opt, key)      // key = "end:<id>"
      else if (key && key !== c.from) this._setRoute(c.from, c.opt, `card:${key}`) // ignore self-drop
    } else {
      this._createBranchCard(c.from, c.opt) // dropped on empty canvas → new branch card
    }
  }

  _deleteEdge(e) {
    if (!e || !e.opt) return
    this._setRoute(e.from, e.opt, "") // revert this answer to the default flow
  }

  // Write a routing choice by driving the same inline <select> the card editor
  // uses, so there is ONE source of truth and autosave persists it as usual.
  _setRoute(fromCid, opt, targetValue) {
    const wrap = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(fromCid)}"]`)
    if (!wrap) return
    const sel = opt === "__default__"
      ? wrap.querySelector("[data-logic-default]")
      : wrap.querySelector(`[data-logic-route][data-canonical="${CSS.escape(opt)}"]`)
    if (!sel) return
    sel.dataset.logicSelected = targetValue
    const ed = this._editor()
    ed?.refreshLogicTargets() // rebuild the select's options + apply the new value
    ed?.markDirty()
    this._render()
  }

  // Drop on empty canvas: create a blank card, route this answer to it.
  _createBranchCard(fromCid, opt) {
    const rootEl = document.querySelector("[data-add-question-render-url-value]")
    const url = rootEl?.dataset.addQuestionRenderUrlValue
    const feed = document.querySelector("[data-add-question-target='cardsFeed']")
    if (!url || !feed) return
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({ type: "open_ended", text: "New branch" })
    })
      .then(r => r.json())
      .then(json => {
        if (!json || !json.ok) return
        const tmp = document.createElement("div"); tmp.innerHTML = (json.html || "").trim()
        const card = tmp.firstElementChild
        if (!card) return
        const slot = document.createElement("div"); slot.className = "card-slot"; slot.appendChild(card)
        const insertRow = feed.querySelector(".aq-insert-row")
        if (insertRow) slot.appendChild(insertRow.cloneNode(true))
        feed.appendChild(slot)
        const rootWithEditor = document.querySelector("[data-survey-editor-url-value]")
        this.application.getControllerForElementAndIdentifier(rootWithEditor, "type-panel")?.registerCard(card)
        this._editor()?.refreshAll() // renumber + refreshLogicTargets so the new cid is routable
        const newCid = card.dataset.cardCid
        if (newCid) this._setRoute(fromCid, opt, `card:${newCid}`)
        else { this._editor()?.markDirty(); this._render() }
      })
      .catch(() => { /* best-effort; the creator can add a card manually */ })
  }

  _clientToUser(clientX, clientY) {
    const pt = this._svg.createSVGPoint()
    pt.x = clientX; pt.y = clientY
    const m = this._svg.getScreenCTM()
    return m ? pt.matrixTransform(m.inverse()) : { x: clientX, y: clientY }
  }
}
