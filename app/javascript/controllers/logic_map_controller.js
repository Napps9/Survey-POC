import { Controller } from "@hotwired/stimulus"

// The "zoom out" flow map for answer-branching. Reads the LIVE deck from the
// survey-editor controller (serialize() → cards with cid + logic), builds a
// layered DAG and draws it as hand-rolled inline SVG with cubic-Bézier
// connectors — no external graph library (the importmap has no bundler and the
// app's only precedent is hand-authored SVG). Each card node shows the REAL
// card (design + question + options) as a scaled, sanitised clone inside a
// <foreignObject>; end screens render as finish pills. Pan (drag) + zoom (wheel)
// via the SVG viewBox. On an unpublished Verto it's an editable canvas: drag an
// answer port onto a node to route it, drop on empty space for a new branch
// card, click a connector to remove it — all written back through the card
// editor's own route <select> so autosave persists them.
const SVG = "http://www.w3.org/2000/svg"
const XHTML = "http://www.w3.org/1999/xhtml"
// Card nodes render the REAL card (design + question + options) as a scaled,
// sanitised clone inside a <foreignObject>; heights vary with the clone.
const CARD_W = 320
const CARD_H_MIN = 130
const CARD_H_MAX = 300
const END_W = 200
const END_H = 66
const COL_GAP = 130
const ROW_GAP = 40
const MARGIN = 56
// Vertical gap separating the main flow's band from each branch lane's band,
// and from the endings band — this is what reads as "outside the flow"
// rather than just another row squeezed into the same grid.
const BAND_GAP = 90
// Corner radius for the orthogonal connectors that thread the gutters.
const CONNECTOR_R = 14
// Distinct colours cycled across branch lanes so each reads as a unit.
const LANE_PALETTE = ["#8B85FF", "#01EACB", "#F59E0B", "#F472B6", "#38BDF8", "#A3E635"]

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
    // Manually-dragged node positions (see _makeDraggable), remembered per
    // browser so the layout doesn't snap back to the auto layout on reopen.
    this._manualPos = this._loadManualPos()
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
      // The card's unconditional `next` flow pointer is the "otherwise" for any
      // card type (mirrors LogicGraph): it too replaces the linear fall-through.
      const nx = c.next
      if (!covered && nx && (nx.card || nx.end)) {
        covered = true
        if (nx.card && nodeByKey.has(nx.card)) edges.push({ from: c.cid, to: nx.card, label: "", kind: "next", opt: "__next__" })
        else if (nx.card) edges.push({ from: c.cid, to: null, label: "", kind: "dangling", opt: "__next__" })
        else if (nx.end) edges.push({ from: c.cid, to: ensureEnd(nx.end), label: "", kind: "next", opt: "__next__" })
      }
      if (!covered) {
        if (i + 1 < cards.length) edges.push({ from: c.cid, to: cards[i + 1].cid, label: "", kind: "linear" })
        else edges.push({ from: c.cid, to: ensureEnd("default"), label: "", kind: "linear" })
      }
    })

    const allNodes = [...nodes, ...endNodes.values()]
    const graph = { nodes, allNodes, endNodes, edges, nodeByKey }
    this._attachLanes(graph, cards)
    return graph
  }

  // Derive branch "lanes" from the wiring so a branch reads as a labelled,
  // colour-grouped unit — with correct NESTING. A lane starts at a branch entry
  // (the target of an answer route) and its members are the cards that entry
  // DOMINATES: every path from the deck start to them passes through the entry.
  // Dominators (vs a simple in-degree walk) keep a parent lane intact past the
  // point where a sub-branch rejoins it, and make nested sub-branches fall out
  // as smaller lanes contained in their parent. Each node gets its innermost
  // containing lane (n.lane {label,color}), n.laneEntry, n.laneDepth,
  // n.laneParent (the enclosing lane, for a nested chip), and n.topLane (the
  // OUTERMOST containing lane, i.e. its own visual band — see _layout). No
  // stored data — the label defaults to the answer value (or a card's
  // lane_label).
  _attachLanes(graph, cards) {
    const lanes = this._computeLanes(cards)
    graph.lanes = lanes
    // Each card takes its INNERMOST containing lane (smallest member set) as its
    // colour; the next-larger containing lane is its parent (for a nested chip).
    // A card in a SIMPLE lane (a plain chain, no sub-branches) also gets reorder
    // affordances based on its position in that lane's spine.
    graph.nodes.forEach(n => {
      const containing = lanes.filter(l => l.members.has(n.key)).sort((a, b) => a.members.size - b.members.size)
      if (!containing.length) return
      const lane = containing[0]
      n.lane = lane
      n.laneEntry = lane.entry === n.key
      n.laneDepth = containing.length
      n.laneParent = containing[1] || null
      n.topLane = containing[containing.length - 1]
      if (lane.simple) {
        const idx = lane.spine.indexOf(n.key)
        if (idx >= 0) n.reorder = { up: idx > 0, down: idx < lane.spine.length - 1 }
      }
    })
  }

  // The branch lanes for a deck (shared by rendering and reorder). A lane =
  // an answer-route target's DOMINATED region; each carries its entry, label,
  // colour, member set, inbound route, the main continuation `spine` (entry →
  // continuation → … up to the rejoin), the encoded `rejoin` target, and
  // `simple` (spine covers every member ⇒ a plain chain safe to reorder).
  _computeLanes(cards) {
    const cids = cards.map(c => c.cid).filter(Boolean)
    if (!cids.length) return []
    const byCid = new Map(cards.map(c => [c.cid, c]))
    const start = cids[0]

    const adj = new Map(cids.map(c => [c, []]))
    const link = (from, to) => { if (byCid.has(to) && adj.has(from)) adj.get(from).push(to) }
    cards.forEach((c, i) => {
      let covered = false
      const L = c.logic
      if (L && Array.isArray(L.routes)) L.routes.forEach(r => { if (r && r.to && r.to.card) link(c.cid, r.to.card) })
      if (L && L.default && (L.default.card || L.default.end)) { covered = true; if (L.default.card) link(c.cid, L.default.card) }
      if (!covered && c.next && (c.next.card || c.next.end)) { covered = true; if (c.next.card) link(c.cid, c.next.card) }
      if (!covered && i + 1 < cards.length && cards[i + 1].cid) link(c.cid, cards[i + 1].cid)
    })
    const reach = (skip) => {
      const seen = new Set(), stack = [start]
      while (stack.length) {
        const x = stack.pop()
        if (x === skip || seen.has(x) || !adj.has(x)) continue
        seen.add(x)
        adj.get(x).forEach(y => { if (y !== skip) stack.push(y) })
      }
      return seen
    }
    const reach0 = reach(null)

    const lanes = []
    const seenEntry = new Set()
    cards.forEach(c => {
      if (!c.logic || !Array.isArray(c.logic.routes)) return
      c.logic.routes.forEach(r => {
        const E = r && r.to && r.to.card
        if (!E || !byCid.has(E) || !reach0.has(E) || seenEntry.has(E)) return
        seenEntry.add(E)
        const without = reach(E)
        const members = new Set([...reach0].filter(x => x === E || !without.has(x)))
        const label = (byCid.get(E).lane_label || (r.match && r.match.value) || "Branch").toString()
        lanes.push({ entry: E, label, members, inbound: { cid: c.cid, answer: (r.match && r.match.value) || "" } })
      })
    })
    lanes.forEach((l, i) => {
      l.color = LANE_PALETTE[i % LANE_PALETTE.length]
      const spine = [], seen = new Set()
      let cur = l.entry
      while (cur && l.members.has(cur) && !seen.has(cur)) {
        seen.add(cur); spine.push(cur)
        cur = this._contCid(byCid.get(cur), cards)
      }
      l.spine = spine
      l.rejoin = spine.length ? this._contTarget(byCid.get(spine[spine.length - 1]), cards) : ""
      l.simple = spine.length === l.members.size
    })
    return lanes
  }

  // A card's main continuation as an encoded target ("card:<cid>" | "end:<id>"):
  // its answer-logic default, else its `next`, else the linear next card, else
  // the finish. (Answer routes are NOT continuations — they open sub-branches.)
  _contTarget(card, cards) {
    if (!card) return ""
    const d = card.logic && card.logic.default
    if (d && d.card) return `card:${d.card}`
    if (d && d.end) return `end:${d.end}`
    if (card.next && card.next.card) return `card:${card.next.card}`
    if (card.next && card.next.end) return `end:${card.next.end}`
    const i = cards.findIndex(c => c.cid === card.cid)
    return (i >= 0 && i + 1 < cards.length && cards[i + 1].cid) ? `card:${cards[i + 1].cid}` : "end:default"
  }

  _contCid(card, cards) {
    const t = this._contTarget(card, cards)
    return t.startsWith("card:") ? t.slice(5) : null
  }

  // Longest-path layering from the entry (card 0), cycle-safe, gives every
  // node a COLUMN. Unreached cards are pushed to their own column past the
  // deepest reachable one, and end nodes sit one column further still. Which
  // ROW/band a node lands in is a separate concern — see the banding pass
  // below — so branches and endings share the main flow's column grid
  // (roughly lining up under where they forked) without sharing its row.
  _layout(graph) {
    const { nodes, endNodes, edges } = graph
    const adj = new Map(nodes.map(n => [n.key, []]))
    edges.forEach(e => { if (e.to && adj.has(e.from) && adj.has(e.to)) adj.get(e.from).push(e.to) })

    const layer = new Map()
    if (nodes.length) layer.set(nodes[0].key, 0)
    // Relax N times (bounded so weaving cycles can't loop forever). A genuine
    // DAG never needs a path longer than nodes.length - 1 hops, so cand is
    // clamped to nodes.length: a cycle (e.g. a route that loops back to an
    // earlier card) would otherwise keep compounding every pass, ballooning
    // the canvas width into the tens of thousands of pixels and squeezing
    // every card into an unreadable sliver in the corner.
    for (let pass = 0; pass < nodes.length + 1; pass++) {
      edges.forEach(e => {
        if (!e.to || !adj.has(e.to)) return
        if (!layer.has(e.from)) return
        const cand = Math.min(layer.get(e.from) + 1, nodes.length)
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

    // Per-node dimensions: a card node is the real card scaled to CARD_W (its
    // height follows the clone, clamped); end nodes are compact pills.
    graph.nodes.forEach(n => {
      const src = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(n.key)}"] .split-card`)
      const r = src && src.getBoundingClientRect()
      const naturalW = (r && r.width) || 680
      const naturalH = (r && r.height) || 360
      n.w = CARD_W
      n.scale = CARD_W / naturalW
      n.naturalW = naturalW
      n.h = Math.max(CARD_H_MIN, Math.min(CARD_H_MAX, Math.round(naturalH * n.scale)))
    })
    endNodes.forEach(n => { n.w = END_W; n.h = END_H })

    // ── banding: keep branches and endings OUT of the main flow's row ──────
    // Every node lands in a BAND: 0 is the main spine (cards in no lane), one
    // band per TOP-LEVEL branch lane (a lane not itself nested inside another —
    // a nested sub-branch shares its parent's band; the lane chip + colour
    // already read the nesting), and a final band holds every finish/end node,
    // regardless of which lane or card reaches it. Bands stack top to bottom
    // with a clear gap, so a branch or an ending never shares a row with the
    // normal flow — it reads as a separate lane of its own. Columns within a
    // band still key off the longest-path `layer`, so a branch's cards line up
    // under roughly where they forked from the main flow.
    const lanes = graph.lanes || []
    const isTopLane = (l) => !lanes.some(o => o !== l && o.members.size > l.members.size &&
      [ ...l.members ].every(m => o.members.has(m)))
    const topLanes = lanes.filter(isTopLane)
      .sort((a, b) => (layer.get(a.entry) ?? 0) - (layer.get(b.entry) ?? 0))
    const bandOfLane = new Map(topLanes.map((l, i) => [ l, i + 1 ]))
    const endBand = topLanes.length + 1
    const bandOf = (n) => {
      if (n.kind === "end") return endBand
      if (!n.lane) return 0
      return bandOfLane.get(n.topLane || n.lane) ?? 0
    }

    const byBand = new Map()
    graph.allNodes.forEach(n => {
      const b = bandOf(n)
      if (!byBand.has(b)) byBand.set(b, [])
      byBand.get(b).push(n)
    })

    let bandTop = MARGIN
    ;[ ...byBand.keys() ].sort((a, b) => a - b).forEach(b => {
      // Order within each band's layer/column by original index (cards) /
      // insertion (ends), then stack each column independently by cumulative
      // height (nodes vary in size) — same per-column stacking as before,
      // just scoped to this band instead of the whole canvas.
      const byLayer = new Map()
      byBand.get(b).forEach(n => {
        const L = layer.get(n.key) ?? 0
        if (!byLayer.has(L)) byLayer.set(L, [])
        byLayer.get(L).push(n)
      })
      let bandHeight = 0
      byLayer.forEach((list, L) => {
        list.sort((x, y) => (x.index ?? 999) - (y.index ?? 999))
        let y = bandTop
        list.forEach(n => {
          n.x = MARGIN + L * (CARD_W + COL_GAP)
          n.y = y
          y += n.h + ROW_GAP
        })
        bandHeight = Math.max(bandHeight, y - bandTop)
      })
      bandTop += bandHeight + BAND_GAP
    })

    // A manually dragged node (see _makeDraggable) always wins over the
    // computed slot — it's remembered per node key (see _setManualPos) so it
    // survives the next render instead of snapping back to the auto layout.
    graph.allNodes.forEach(n => {
      const pos = this._manualPos && this._manualPos.get(n.key)
      if (pos) { n.x = pos.x; n.y = pos.y }
    })

    // The initial view (see _render) fits this exact bounding box, not a
    // fixed (0,0) origin — a node dragged up or left of the auto layout would
    // otherwise sit outside a viewBox that always started at the top-left
    // corner, and only be reachable by panning after the map reopens.
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    graph.allNodes.forEach(n => {
      minX = Math.min(minX, n.x); minY = Math.min(minY, n.y)
      maxX = Math.max(maxX, n.x + n.w); maxY = Math.max(maxY, n.y + n.h)
    })
    return { x: minX - MARGIN, y: minY - MARGIN, width: (maxX - minX) + 2 * MARGIN, height: (maxY - minY) + 2 * MARGIN }
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

    const { x, y, width, height } = this._layout(graph)
    // Keep the current pan/zoom across edit re-renders; re-fit only on open.
    if (!this._vb) this._vb = { x, y, w: width, h: height }
    svg.setAttribute("viewBox", `${this._vb.x} ${this._vb.y} ${this._vb.w} ${this._vb.h}`)
    svg.appendChild(this._defs())

    const posByKey = new Map(graph.allNodes.map(n => [n.key, n]))
    this._posByKey = posByKey
    this._edgeRecords = []
    const eLayer = this._g()
    graph.edges.forEach(e => {
      const rec = this._edgePath(e, posByKey)
      if (rec) { eLayer.appendChild(rec.g); this._edgeRecords.push(rec) }
    })
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
    defs.appendChild(mk("arrow-next", "#8B85FF"))
    return defs
  }

  // Pure geometry for an edge given the current node positions — split out
  // from _edgePath so a drag (see _makeDraggable / _refreshEdgesForNode) can
  // recompute just the numbers and patch the existing DOM instead of
  // rebuilding it every pointermove.
  _edgeGeometry(e, posByKey) {
    const from = posByKey.get(e.from)
    if (!from) return null
    const sx = from.x + from.w, sy = from.y + this._portY(from, e.opt)
    let tx, ty
    if (e.to && posByKey.has(e.to)) {
      const to = posByKey.get(e.to); tx = to.x; ty = to.y + to.h / 2
    } else {
      tx = sx + 90; ty = sy // dangling: a short stub
    }
    return { sx, sy, tx, ty, d: this._connectorPath(sx, sy, tx, ty) }
  }

  _edgePath(e, posByKey) {
    const geo = this._edgeGeometry(e, posByKey)
    if (!geo) return null
    const { sx, sy, tx, ty, d } = geo
    const style = {
      route:   { stroke: "#01EACB", dash: "", marker: "arrow-route",  w: 2 },
      next:    { stroke: "#8B85FF", dash: "", marker: "arrow-next",   w: 2 },
      default: { stroke: "rgba(255,255,255,0.5)", dash: "5 5", marker: "arrow-faint", w: 1.6 },
      linear:  { stroke: "rgba(255,255,255,0.22)", dash: "4 6", marker: "arrow-faint", w: 1.4 },
      dangling:{ stroke: "#F87171", dash: "3 4", marker: "arrow-danger", w: 1.8 }
    }[e.kind] || { stroke: "rgba(255,255,255,0.3)", dash: "", marker: "arrow-faint", w: 1.4 }

    const g = this._g()

    // When editing, a fat invisible hit-path makes the connector easy to click
    // to remove (reverts that answer to the default flow).
    const deletable = this.editableValue && e.opt
    let hitEl = null
    if (deletable) {
      hitEl = document.createElementNS(SVG, "path")
      hitEl.setAttribute("d", d); hitEl.setAttribute("fill", "none")
      hitEl.setAttribute("stroke", "transparent"); hitEl.setAttribute("stroke-width", "14")
      hitEl.style.cursor = "pointer"
      const title = document.createElementNS(SVG, "title"); title.textContent = "Click to remove this route"
      hitEl.appendChild(title)
      hitEl.addEventListener("click", () => this._deleteEdge(e))
      g.appendChild(hitEl)
    }

    const pathEl = document.createElementNS(SVG, "path")
    pathEl.setAttribute("d", d)
    pathEl.setAttribute("fill", "none")
    pathEl.setAttribute("stroke", style.stroke)
    pathEl.setAttribute("stroke-width", style.w)
    if (style.dash) pathEl.setAttribute("stroke-dasharray", style.dash)
    pathEl.setAttribute("marker-end", `url(#${style.marker})`)
    pathEl.style.pointerEvents = "none"
    g.appendChild(pathEl)

    let textEl = null
    if (e.label) {
      // Sit the label on this edge's first horizontal run, in the clear gutter
      // just right of its source port — at the port's own height, so several
      // routes leaving one card keep their labels separated (never stacked).
      const forward = tx > sx + 2 * CONNECTOR_R
      textEl = document.createElementNS(SVG, "text")
      textEl.setAttribute("x", forward ? sx + (tx - sx) * 0.25 : sx + (tx - sx) * 0.42)
      textEl.setAttribute("y", forward ? sy - 6 : sy + (ty - sy) * 0.42 - 6)
      textEl.setAttribute("text-anchor", "middle")
      textEl.setAttribute("fill", e.kind === "dangling" ? "#F87171" : (e.kind === "route" ? "#01EACB" : "rgba(255,255,255,0.5)"))
      textEl.setAttribute("font-size", "11"); textEl.setAttribute("font-family", "'ABeeZee', sans-serif")
      textEl.textContent = this._trunc(e.label, 18)
      g.appendChild(textEl)
    }
    return { g, e, pathEl, hitEl, textEl }
  }

  // Live-updates every edge touching a just-moved node (see _makeDraggable) —
  // patches existing path/label elements in place rather than re-rendering
  // the whole map on every pointermove.
  _refreshEdgesForNode(key) {
    if (!this._edgeRecords || !this._posByKey) return
    this._edgeRecords.forEach(rec => {
      if (rec.e.from !== key && rec.e.to !== key) return
      const geo = this._edgeGeometry(rec.e, this._posByKey)
      if (!geo) return
      const { sx, sy, tx, ty, d } = geo
      rec.pathEl.setAttribute("d", d)
      if (rec.hitEl) rec.hitEl.setAttribute("d", d)
      if (rec.textEl) {
        const forward = tx > sx + 2 * CONNECTOR_R
        rec.textEl.setAttribute("x", forward ? sx + (tx - sx) * 0.25 : sx + (tx - sx) * 0.42)
        rec.textEl.setAttribute("y", forward ? sy - 6 : sy + (ty - sy) * 0.42 - 6)
      }
    })
  }

  // An orthogonal "elbow" connector routed through the empty gutter BETWEEN the
  // two card columns: it leaves the source horizontally, makes its whole vertical
  // turn in the clear channel (mid-way between the cards, where no card sits), then
  // enters the target horizontally. This keeps the line outside every card body so
  // its full path stays visible — cards no longer paint over it. Corners are
  // rounded for legibility. Back/overlapping edges (cycles, no forward gutter) keep
  // the soft Bézier, since there is no clean channel to route them through.
  _connectorPath(sx, sy, tx, ty) {
    const R = CONNECTOR_R
    if (tx > sx + 2 * R) {
      const midX = (sx + tx) / 2
      if (Math.abs(ty - sy) < 1) return `M ${sx} ${sy} L ${tx} ${ty}` // straight — same height
      const dirY = ty > sy ? 1 : -1
      const r = Math.min(R, (tx - sx) / 2, Math.abs(ty - sy) / 2)
      return `M ${sx} ${sy}` +
        ` H ${midX - r}` +
        ` Q ${midX} ${sy} ${midX} ${sy + dirY * r}` +
        ` V ${ty - dirY * r}` +
        ` Q ${midX} ${ty} ${midX + r} ${ty}` +
        ` H ${tx}`
    }
    const dx = Math.max(40, Math.abs(tx - sx))
    return `M ${sx} ${sy} C ${sx + dx * 0.5} ${sy}, ${tx - dx * 0.5} ${ty}, ${tx} ${ty}`
  }

  _cardNode(n) {
    const g = this._g()
    g.setAttribute("transform", `translate(${n.x} ${n.y})`)
    g.dataset.nodeKey = n.key
    g.dataset.nodeKind = "card"
    n.group = g

    // The real card (design + question + options), scaled to fit the node.
    const fo = document.createElementNS(SVG, "foreignObject")
    fo.setAttribute("x", 0); fo.setAttribute("y", 0)
    fo.setAttribute("width", n.w); fo.setAttribute("height", n.h)
    const box = document.createElementNS(XHTML, "div")
    box.setAttribute("class", `lm-card-box${n.unreachable ? " lm-card-unreachable" : ""}`)
    // Lane grouping: tint the frame in the lane's colour so a branch's cards
    // read as one unit.
    if (n.lane) {
      box.style.borderColor = n.lane.color
      box.style.borderWidth = "2px"
      box.style.boxShadow = `0 0 0 3px ${n.lane.color}22`
    }
    // Carry the Verto's brand palette onto the clone so its design renders true.
    const srcWrap = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(n.key)}"]`)
    if (srcWrap) {
      const cs = getComputedStyle(srcWrap)
      ;["--brand-primary", "--brand-cta", "--brand-bg", "--brand-bg-image", "--brand-cta-text", "--brand-primary-text", "--brand-secondary"]
        .forEach(v => { const val = cs.getPropertyValue(v); if (val && val.trim()) box.style.setProperty(v, val.trim()) })
    }
    const clone = this._cloneCard(n.key)
    if (clone) {
      const inner = document.createElementNS(XHTML, "div")
      inner.setAttribute("class", "lm-card-scale")
      inner.setAttribute("style", `width:${n.naturalW}px;transform:scale(${n.scale});transform-origin:top left;`)
      inner.appendChild(clone)
      box.appendChild(inner)
    } else {
      box.appendChild(this._fallbackCard(n))
    }
    fo.appendChild(box)
    g.appendChild(fo)

    // Lane label chip on the branch's entry card — names the lane (defaults to
    // the answer that opens it), sitting just above the card in the lane colour.
    if (n.lane && n.laneEntry) g.appendChild(this._laneChip(n))

    // Reorder controls for a card inside a simple lane — move it earlier/later
    // in the branch's question order (rewires the chain).
    if (this.editableValue && n.reorder) {
      g.appendChild(this._reorderBtn(n.w - 46, -25, "▲", n.reorder.up, () => this._moveInLane(n.key, -1)))
      g.appendChild(this._reorderBtn(n.w - 23, -25, "▼", n.reorder.down, () => this._moveInLane(n.key, 1)))
    }

    // A transparent hit layer over the card: drag it anywhere to reposition
    // it (see _makeDraggable), or a plain click jumps to it in the deck — and
    // it's the drop target for a dragged route (the card clone itself is
    // pointer-inert).
    const hit = document.createElementNS(SVG, "rect")
    hit.setAttribute("width", n.w); hit.setAttribute("height", n.h); hit.setAttribute("rx", 16)
    hit.setAttribute("fill", "transparent")
    g.appendChild(hit)
    this._makeDraggable(hit, n, () => this._jumpTo(n.key))

    // A small caption chip (card number) so nodes are identifiable when zoomed out.
    const cap = this._text(10, n.h - 8, n.unreachable ? "unreachable" : `Card ${n.num}`,
      { size: 11, fill: n.unreachable ? "#F87171" : "rgba(255,255,255,0.55)" })
    g.appendChild(cap)

    // Editable output ports on the right edge. Routable cards get one per answer
    // (+ an "otherwise" default); every other card type gets a single "flow" port
    // that sets its unconditional `next` — this is what chains a lane of plain
    // cards and rejoins the main flow.
    if (this.editableValue) {
      if (this.constructor.ROUTABLE.includes(n.type)) {
        this._portLayout(n).forEach(port => {
          g.appendChild(this._port(n.w, port.py, `Drag to route "${port.label}"`,
            (ev) => this._beginConnect(n.key, port.opt, n.x + n.w, n.y + port.py, ev)))
        })
      } else {
        const py = n.h / 2
        g.appendChild(this._port(n.w, py, "Drag to set where this card leads next",
          (ev) => this._beginConnect(n.key, "__next__", n.x + n.w, n.y + py, ev)))
      }
    }
    return g
  }

  // The lane's name chip, drawn just above its entry card in the lane colour.
  // A nested lane is prefixed with its parent's name ("UK ▸ No") so depth reads.
  _laneChip(n) {
    const g = this._g()
    const prefix = n.laneParent ? this._trunc(n.laneParent.label, 10) + " ▸ " : ""
    const label = "⎇ " + prefix + this._trunc(n.lane.label, 16)
    const w = Math.min(n.w, 20 + label.length * 6.4)
    const rect = document.createElementNS(SVG, "rect")
    rect.setAttribute("x", 0); rect.setAttribute("y", -25)
    rect.setAttribute("width", w); rect.setAttribute("height", 20); rect.setAttribute("rx", 10)
    rect.setAttribute("fill", n.lane.color)
    g.appendChild(rect)
    g.appendChild(this._text(9, -11, label, { size: 11, fill: "#14172A" }))
    // Click to rename the branch (editable maps only).
    if (this.editableValue) {
      const title = document.createElementNS(SVG, "title"); title.textContent = "Rename this branch"
      g.appendChild(title)
      g.style.cursor = "text"
      g.addEventListener("pointerdown", (ev) => ev.stopPropagation())
      g.addEventListener("click", (ev) => { ev.stopPropagation(); this._renameLane(n.lane.entry, n.lane.label) })
    }
    return g
  }

  // Rename a branch — stored as lane_label on its entry card, which the lane
  // detector prefers over the answer-derived default. Persisted via autosave.
  _renameLane(entryCid, current) {
    if (!this.editableValue) return
    const name = window.prompt("Branch name", current || "")
    if (name == null) return // cancelled
    const wrap = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(entryCid)}"]`)
    if (!wrap) return
    const trimmed = name.trim()
    if (trimmed) wrap.dataset.cardLaneLabel = trimmed
    else delete wrap.dataset.cardLaneLabel
    this._editor()?.markDirty()
    this._render()
  }

  // A small up/down button to reorder a card within its lane. Dimmed + inert at
  // the ends of the lane (enabled=false).
  _reorderBtn(x, y, glyph, enabled, onClick) {
    const g = this._g()
    const rect = document.createElementNS(SVG, "rect")
    rect.setAttribute("x", x); rect.setAttribute("y", y)
    rect.setAttribute("width", 20); rect.setAttribute("height", 20); rect.setAttribute("rx", 6)
    rect.setAttribute("fill", enabled ? "rgba(255,255,255,0.14)" : "rgba(255,255,255,0.04)")
    rect.setAttribute("stroke", "rgba(255,255,255,0.2)")
    g.appendChild(rect)
    g.appendChild(this._text(x + 5, y + 14, glyph, { size: 11, fill: enabled ? "#fff" : "rgba(255,255,255,0.25)" }))
    if (enabled) {
      const title = document.createElementNS(SVG, "title"); title.textContent = "Reorder in this branch"
      g.appendChild(title)
      g.style.cursor = "pointer"
      g.addEventListener("pointerdown", (ev) => ev.stopPropagation())
      g.addEventListener("click", (ev) => { ev.stopPropagation(); onClick() })
    }
    return g
  }

  // A draggable output port dot on a node's right edge.
  _port(cx, cy, tip, onDown) {
    const dot = document.createElementNS(SVG, "circle")
    dot.setAttribute("cx", cx); dot.setAttribute("cy", cy); dot.setAttribute("r", 6)
    dot.setAttribute("fill", "#615BF5"); dot.setAttribute("stroke", "#fff"); dot.setAttribute("stroke-width", "1.5")
    dot.style.cursor = "crosshair"
    const title = document.createElementNS(SVG, "title"); title.textContent = tip
    dot.appendChild(title)
    dot.addEventListener("pointerdown", (ev) => { ev.stopPropagation(); onDown(ev) })
    return dot
  }

  // Port positions down the right edge — shared by port drawing and edge anchors.
  _portLayout(node) {
    const opts = [...(node.options || []).map(o => ({ opt: o, label: o })), { opt: "__default__", label: "otherwise" }]
    const count = opts.length
    const gap = Math.min(26, (node.h - 28) / Math.max(1, count - 1))
    const startY = Math.max(18, (node.h - (count - 1) * gap) / 2)
    return opts.map((o, k) => ({ ...o, py: startY + k * gap }))
  }

  _portY(node, opt) {
    if (opt == null || node.kind !== "card" || !this.constructor.ROUTABLE.includes(node.type)) return node.h / 2
    return (this._portLayout(node).find(p => p.opt === opt)?.py) ?? node.h / 2
  }

  // A sanitised, inert clone of the real card's .split-card: strips the editor
  // chrome and every controller/action/contenteditable so the map never wires
  // up duplicate widgets — it's a static picture of design + question + options.
  _cloneCard(cid) {
    const src = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(cid)}"] .split-card`)
    if (!src) return null
    const clone = src.cloneNode(true)
    clone.querySelectorAll(".logic-branch-block, .logic-route-select, .logic-default-row, .mark-correct, .pick-item-delete, .pick-add-btn, [data-card-editor-add], .card-reorder, .card-delete-btn")
      .forEach(el => el.remove())
    const scrub = (el) => {
      el.removeAttribute("data-controller")
      el.removeAttribute("data-action")
      el.removeAttribute("contenteditable")
      el.removeAttribute("id")
      if (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") el.removeAttribute("name")
      el.querySelectorAll?.("*").forEach(scrub)
    }
    scrub(clone)
    return clone
  }

  _fallbackCard(n) {
    const d = document.createElementNS(XHTML, "div")
    d.setAttribute("style", "padding:14px;color:#fff;font-family:'ABeeZee',sans-serif;")
    d.textContent = n.text || this._badge(n.type)
    return d
  }

  _endNode(n) {
    const g = this._g()
    g.setAttribute("transform", `translate(${n.x} ${n.y})`)
    g.dataset.nodeKey = n.key
    g.dataset.nodeKind = "end"
    n.group = g
    const rect = document.createElementNS(SVG, "rect")
    rect.setAttribute("width", n.w); rect.setAttribute("height", n.h); rect.setAttribute("rx", n.h / 2)
    rect.setAttribute("fill", "rgba(1,234,203,0.12)"); rect.setAttribute("stroke", "#01EACB"); rect.setAttribute("stroke-width", "1.5")
    g.appendChild(rect)
    g.appendChild(this._text(20, 28, "FINISH", { size: 10, fill: "rgba(1,234,203,0.85)", spacing: "0.08em" }))
    g.appendChild(this._text(20, 46, "🏁 " + this._trunc(n.text, 20), { size: 13, fill: "#fff" }))

    // A transparent hit layer on top: drag anywhere on the pill to reposition
    // it (see _makeDraggable). No click behaviour — there's nothing in the
    // deck to jump to for a finish screen.
    const hit = document.createElementNS(SVG, "rect")
    hit.setAttribute("width", n.w); hit.setAttribute("height", n.h); hit.setAttribute("rx", n.h / 2)
    hit.setAttribute("fill", "transparent")
    g.appendChild(hit)
    this._makeDraggable(hit, n, null)
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

  // ── free positioning: drag a node anywhere, remembered per browser ─────────

  // Keyed by the survey's own URL so different Vertos (and different browsers)
  // never collide; best-effort only — a manual layout is a viewing convenience,
  // not survey data, so it's fine if it doesn't follow the creator across
  // devices, and any storage failure (quota, private mode) just falls back to
  // the auto layout instead of breaking the map.
  _posStorageKey() {
    const el = document.querySelector("[data-survey-editor-url-value]")
    return `logic-map-positions:${el?.dataset.surveyEditorUrlValue || "unknown"}`
  }

  _loadManualPos() {
    const map = new Map()
    try {
      const raw = window.localStorage.getItem(this._posStorageKey())
      if (raw) {
        Object.entries(JSON.parse(raw)).forEach(([ key, pos ]) => {
          if (pos && Number.isFinite(pos.x) && Number.isFinite(pos.y)) map.set(key, pos)
        })
      }
    } catch (_) { /* corrupt or unavailable storage — fall back to auto layout */ }
    return map
  }

  _setManualPos(key, x, y) {
    this._manualPos.set(key, { x, y })
    try {
      window.localStorage.setItem(this._posStorageKey(), JSON.stringify(Object.fromEntries(this._manualPos)))
    } catch (_) { /* best-effort; the drag still holds for this open session */ }
  }

  // Wires a node's invisible hit layer to drag freely: a short movement
  // threshold tells a genuine drag apart from a plain click (onClick, if
  // given — a card jumps to it in the deck; an ending has none). Dragging
  // stops the pointerdown from bubbling to the canvas's own pan handler, and
  // live-updates any edge touching this node so connectors track the node
  // instead of lagging a frame behind until the next full render.
  _makeDraggable(hit, n, onClick) {
    hit.style.cursor = "grab"
    let drag = null
    hit.addEventListener("pointerdown", (ev) => {
      if (ev.button != null && ev.button !== 0) return
      ev.stopPropagation()
      try { hit.setPointerCapture(ev.pointerId) } catch (_) {}
      // Bring the node to the front of its layer so dragging it over another
      // node doesn't leave it painting underneath for the rest of this render.
      if (n.group && n.group.parentNode) n.group.parentNode.appendChild(n.group)
      const p = this._clientToUser(ev.clientX, ev.clientY)
      drag = { pointerId: ev.pointerId, startUX: p.x, startUY: p.y, startNX: n.x, startNY: n.y, moved: false }
    })
    hit.addEventListener("pointermove", (ev) => {
      if (!drag || ev.pointerId !== drag.pointerId) return
      const p = this._clientToUser(ev.clientX, ev.clientY)
      const dx = p.x - drag.startUX, dy = p.y - drag.startUY
      if (!drag.moved && Math.hypot(dx, dy) < 4) return
      drag.moved = true
      hit.style.cursor = "grabbing"
      n.x = drag.startNX + dx
      n.y = drag.startNY + dy
      n.group?.setAttribute("transform", `translate(${n.x} ${n.y})`)
      this._refreshEdgesForNode(n.key)
    })
    const finish = (ev) => {
      if (!drag || ev.pointerId !== drag.pointerId) return
      try { hit.releasePointerCapture(ev.pointerId) } catch (_) {}
      hit.style.cursor = "grab"
      const moved = drag.moved
      drag = null
      if (moved) this._setManualPos(n.key, n.x, n.y)
      else if (onClick) onClick()
    }
    hit.addEventListener("pointerup", finish)
    hit.addEventListener("pointercancel", finish)
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
      if (grp.dataset.nodeKind === "end") this._applyTarget(c.from, c.opt, key)      // key = "end:<id>"
      else if (key && key !== c.from) this._applyTarget(c.from, c.opt, `card:${key}`) // ignore self-drop
    } else {
      this._createBranchCard(c.from, c.opt) // dropped on empty canvas → new branch card
    }
  }

  _deleteEdge(e) {
    if (!e || !e.opt) return
    this._applyTarget(e.from, e.opt, "") // revert this answer / flow to the linear default
  }

  // Route a dragged connection to the right writer: a card's unconditional
  // `next` flow pointer, or one of its per-answer route selects.
  _applyTarget(fromCid, opt, targetValue) {
    if (opt === "__next__") this._setNext(fromCid, targetValue)
    else this._setRoute(fromCid, opt, targetValue)
  }

  // Set (or clear, on "") a card's unconditional `next` flow pointer directly on
  // its wrap dataset — the serialiser reads data-card-next, so autosave persists
  // it and the player follows it. This is how branch lanes chain and rejoin.
  _setNext(fromCid, targetValue) {
    const wrap = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(fromCid)}"]`)
    if (!wrap) return
    let next = null
    if (typeof targetValue === "string" && targetValue.startsWith("card:")) next = { card: targetValue.slice(5) }
    else if (typeof targetValue === "string" && targetValue.startsWith("end:")) next = { end: targetValue.slice(4) }
    if (next && (next.card || next.end)) wrap.dataset.cardNext = JSON.stringify(next)
    else delete wrap.dataset.cardNext
    this._editor()?.markDirty()
    this._render()
  }

  // Reorder a card within its (simple) lane by swapping it with an adjacent
  // spine card and rewiring the chain: the predecessor (the inbound route if the
  // entry moves, else the prior spine card) now leads to the moved-up card, that
  // card leads to its new neighbour, and the neighbour leads on to what followed.
  // Restricted to simple lanes so no sub-branch rejoin is silently broken.
  _moveInLane(cid, dir) {
    const cards = this._editor()?.serialize()?.cards || []
    const byCid = new Map(cards.map(c => [c.cid, c]))
    const lane = this._computeLanes(cards)
      .filter(l => l.simple && l.members.has(cid))
      .sort((a, b) => a.members.size - b.members.size)[0]
    if (!lane) return
    const spine = lane.spine
    const i = spine.indexOf(cid), j = i + dir
    if (i < 0 || j < 0 || j >= spine.length) return
    const a = Math.min(i, j)                 // lower index of the swapped pair
    const A = spine[a], B = spine[a + 1]      // A precedes B before the swap
    const contOpt = (k) => this.constructor.ROUTABLE.includes(byCid.get(k)?.type) ? "__default__" : "__next__"
    const after = (a + 1 === spine.length - 1) ? lane.rejoin : `card:${spine[a + 2]}` // what B led to

    // Keep a custom name attached to the lane's first card when the entry moves.
    if (a === 0) {
      const wrapA = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(A)}"]`)
      const wrapB = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(B)}"]`)
      const lbl = wrapA?.dataset.cardLaneLabel
      if (lbl && wrapB) { wrapB.dataset.cardLaneLabel = lbl; delete wrapA.dataset.cardLaneLabel }
      this._setRoute(lane.inbound.cid, lane.inbound.answer, `card:${B}`) // inbound → new first (B)
    } else {
      this._applyTarget(spine[a - 1], contOpt(spine[a - 1]), `card:${B}`) // prior spine card → B
    }
    this._applyTarget(B, contOpt(B), `card:${A}`) // B → A
    this._applyTarget(A, contOpt(A), after)       // A → what B used to lead to
  }

  // Write a routing choice by driving the same inline <select> the card editor
  // uses, so there is ONE source of truth and autosave persists it as usual.
  _setRoute(fromCid, opt, targetValue) {
    // The route selects may have been relocated into the sidebar's Branching
    // tab for the active card, so resolve their current home via the editor.
    const scope = this._editor()?.logicScopeForCid(fromCid)
    if (!scope) return
    const sel = opt === "__default__"
      ? scope.querySelector("[data-logic-default]")
      : scope.querySelector(`[data-logic-route][data-canonical="${CSS.escape(opt)}"]`)
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
    // Where the source currently continues for this opt — the new card inherits
    // it as its own `next`, so a fresh branch card SPLICES into the flow and
    // rejoins the main line instead of dead-ending at the finish.
    const rejoin = this._continuationFor(fromCid, opt)
    // Where the source's OTHER (unmatched) answers currently continue. Splicing
    // the new card right after the source makes it the source's linear
    // fall-through, which would silently reroute those answers through the new
    // card too. Capture their target now (pre-splice) so we can pin it as an
    // explicit default below.
    const otherwise = this._continuationFor(fromCid, "__default__")
    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
      },
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
        // Splice the slot in right after its source card rather than appending
        // to the end of the deck: the new card's `next` rejoins mid-deck, so
        // tacking it on at the bottom would make the (now-last) original card's
        // own linear fall-through point BACK at it — a cycle that sends the
        // layout's column widths (and the pan/zoom canvas) sky-high.
        const fromSlot = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(fromCid)}"]`)?.closest(".card-slot")
        if (fromSlot && fromSlot.parentElement === feed) fromSlot.after(slot)
        else feed.appendChild(slot)
        const rootWithEditor = document.querySelector("[data-survey-editor-url-value]")
        this.application.getControllerForElementAndIdentifier(rootWithEditor, "type-panel")?.registerCard(card)
        this._editor()?.refreshAll() // renumber + refreshLogicTargets so the new cid is routable
        const newCid = card.dataset.cardCid
        if (newCid) {
          this._applyTarget(fromCid, opt, `card:${newCid}`)           // source → new card
          if (rejoin && rejoin !== `card:${newCid}`) this._setNext(newCid, rejoin) // new card → rejoin
          // Branching a single answer of a routable card: pin the source's
          // "otherwise" default to where its other answers were already going,
          // so they keep their path instead of falling through into the
          // just-spliced card. No-op for the default/flow ports (already
          // explicit) and for non-routable cards (no default select to set).
          if (opt !== "__default__" && opt !== "__next__" && otherwise && otherwise !== `card:${newCid}`) {
            this._applyTarget(fromCid, "__default__", otherwise)
          }
        } else { this._editor()?.markDirty(); this._render() }
      })
      .catch(() => { /* best-effort; the creator can add a card manually */ })
  }

  // Where card `fromCid` currently sends flow for `opt` (an answer canonical, or
  // "__next__"): an existing route wins, else the card's default, else its
  // `next`, else the linear next card, else the finish. Returned as an encoded
  // target ("card:<cid>" | "end:<id>" | ""). Used to auto-rejoin new branch cards.
  _continuationFor(fromCid, opt) {
    const cards = this._editor()?.serialize()?.cards || []
    const i = cards.findIndex(c => c.cid === fromCid)
    if (i < 0) return ""
    const c = cards[i]
    const enc = (t) => (t && t.card) ? `card:${t.card}` : (t && t.end) ? `end:${t.end}` : ""
    if (opt !== "__default__" && opt !== "__next__" && c.logic && Array.isArray(c.logic.routes)) {
      const r = c.logic.routes.find(rt => rt && rt.match && rt.match.value === opt)
      if (r && enc(r.to)) return enc(r.to)
    }
    if (opt !== "__next__" && c.logic && enc(c.logic.default)) return enc(c.logic.default)
    if (enc(c.next)) return enc(c.next)
    if (i + 1 < cards.length && cards[i + 1].cid) return `card:${cards[i + 1].cid}`
    return "end:default"
  }

  _clientToUser(clientX, clientY) {
    const pt = this._svg.createSVGPoint()
    pt.x = clientX; pt.y = clientY
    const m = this._svg.getScreenCTM()
    return m ? pt.matrixTransform(m.inverse()) : { x: clientX, y: clientY }
  }
}
