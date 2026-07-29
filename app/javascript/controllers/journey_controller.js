import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// The Journey — THE Logic & flows surface. A vertical storyboard of the deck
// built from REAL card clones (design + question + options, scaled), where
// the structure is drawn instead of described: linear runs collapse into a
// stack, a routing question fans its answers out as coloured lines into flow
// columns, and the lines merge where paths converge or end at finish flags.
//
// Replaces the old horizontal flow map (logic_map_controller). Same doctrine:
// renders from survey-editor's LIVE serialize(), writes routing back through
// the card editor's own route <select>s so autosave persists everything, and
// portals its overlay to <body> to escape the fullscreen layout's stacking
// context. Layout is ordinary flow layout + wires measured AFTER layout
// (getBoundingClientRect against the scroll container) — no coordinate math.
//
// z-order: this overlay (80) sits under the Logic settings modal (90) and the
// generate-flow modal (100), so both open ABOVE the journey.
const CARD_W = 250      // on-canvas width of a card clone
const STACK_MIN = 2     // linear spine runs this long collapse into a stack

export default class extends Controller {
  static targets = [ "overlay", "scroll", "wires", "canvas" ]
  static values = { ends: { type: Array, default: [] }, editable: { type: Boolean, default: false } }

  connect() {
    // NOT portalled: the overlay stays inside the editor's fixed wrapper so
    // it shares a stacking context with the settings modal (z 90) and the
    // generate modal (z 100) — both must open ABOVE the journey (z 80). The
    // score modal proves in-wrapper overlays cover the editor fine.
    this._overlay = this.hasOverlayTarget ? this.overlayTarget : null
    this._expanded = new Set() // stack keys the creator has expanded
  }

  openSettings() { this._flows()?.openPanel() }

  open() {
    const editor = this._editor()
    if (!editor) return
    // Logic off ⇒ nothing to draw; send the creator to the settings modal
    // where the feature toggle lives.
    if (!editor.logicValue) { this._flows()?.openPanel(); return }
    // Opened from inside the settings modal (its ⤢ Journey button): the modal
    // sits above this overlay, so step out of it first.
    this._flows()?.closePanel()
    this._overlay.classList.remove("hidden")
    document.body.style.overflow = "hidden"
    this._esc = (e) => {
      if (e.key !== "Escape") return
      // The settings modal stacks above the journey and owns this Esc.
      const settings = document.querySelector(".logic-modal-overlay:not(.hidden)")
      if (!settings) this.close()
    }
    window.addEventListener("keydown", this._esc)
    this._render()
  }

  // Root data-action hook (survey-editor:refreshed): keep the canvas live
  // while the deck changes underneath — e.g. flows created from the settings
  // modal stacked above it. Render-only; cheap enough on structural changes.
  refreshed() {
    if (this._overlay && !this._overlay.classList.contains("hidden")) this._render()
  }

  close() {
    this._overlay.classList.add("hidden")
    document.body.style.overflow = ""
    if (this._esc) window.removeEventListener("keydown", this._esc)
  }

  // ── Build ────────────────────────────────────────────────────────────────

  _render() {
    const editor = this._editor()
    const scroll = this._overlay.querySelector("[data-journey-target='scroll']")
    const canvas = this._overlay.querySelector("[data-journey-target='canvas']")
    const svg = this._overlay.querySelector("[data-journey-target='wires']")
    if (!editor || !canvas || !svg) return
    canvas.textContent = ""
    svg.textContent = ""
    this._nodeByKey = new Map() // "card:<cid>" | "end:<id>" | "flow:<id>" → element

    const { cards } = editor.serialize()
    const flows = editor.flowsList()
    const flowById = new Map(flows.map(f => [ f.id, f ]))
    const flowOfCid = new Map()
    cards.forEach(c => { if (c.flow_id && c.cid) flowOfCid.set(c.cid, c.flow_id) })
    const entryOf = new Map() // flowId → entry cid
    flows.forEach(f => { const e = cards.find(c => c.flow_id === f.id); if (e?.cid) entryOf.set(f.id, e.cid) })

    // Anchor each flow to the SPINE question that (first) routes into it. A
    // flow opened from inside another flow shares that flow's anchor — the
    // wire from the member question still shows the true origin. Unrouted
    // flows anchor at the end (flagged in their lane chip).
    const anchorOf = new Map()
    cards.forEach(c => {
      const routes = (c.logic && Array.isArray(c.logic.routes)) ? c.logic.routes : []
      routes.forEach(r => {
        const target = r?.to?.card && flowOfCid.get(r.to.card)
        if (!target || anchorOf.has(target)) return
        const anchor = c.flow_id ? anchorOf.get(c.flow_id) : c.cid
        if (anchor) anchorOf.set(target, anchor)
      })
    })

    // Walk the spine, collapsing quiet runs; drop each anchor's flow columns
    // in right after its question node.
    const spine = cards.filter(c => !c.flow_id)
    const eventful = new Set() // spine cids that must render individually
    spine.forEach(c => {
      // Every routable question renders on its own WITH its answer chips —
      // wired or not, it's a potential branch point and the chips are how
      // routing starts. Cards that already route always show too.
      const routable = [ "multiple_choice", "yes_no", "scenario" ].includes(c.type) &&
                       Array.isArray(c.options) && c.options.length
      const hasRouting = c.logic && ((Array.isArray(c.logic.routes) && c.logic.routes.length) || c.logic.default)
      if (routable || hasRouting) eventful.add(c.cid)
    })
    flows.forEach(f => { // converge targets stay visible so merge wires land somewhere real
      const ex = f.exit || {}
      if (ex.card) eventful.add(ex.card)
    })
    cards.forEach(c => { if (c.next?.card && !flowOfCid.get(c.next.card)) eventful.add(c.next.card) })

    let run = []
    const flushRun = () => {
      if (!run.length) return
      const key = `${run[0].cid}:${run.length}`
      if (run.length >= STACK_MIN && !this._expanded.has(key)) {
        canvas.appendChild(this._stackNode(run, key, cards))
      } else {
        run.forEach(c => canvas.appendChild(this._cardNode(c, cards, null)))
      }
      run = []
    }
    spine.forEach(c => {
      if (!eventful.has(c.cid)) { run.push(c); return }
      flushRun()
      canvas.appendChild(this._cardNode(c, cards, null))
      const anchored = flows.filter(f => anchorOf.get(f.id) === c.cid && entryOf.has(f.id))
      if (anchored.length) canvas.appendChild(this._colsRow(anchored, cards, flowById, false))
    })
    flushRun()

    // Orphaned / unanchored flows still render, flagged, before the endings.
    const leftovers = flows.filter(f => !anchorOf.has(f.id) && entryOf.has(f.id))
    if (leftovers.length) canvas.appendChild(this._colsRow(leftovers, cards, flowById, true))

    // Finish flags: the shared thank-you plus every extra end screen.
    const flagRow = document.createElement("div")
    flagRow.className = "j-flags"
    const ends = [ { id: "default", title: t("editor.flows.finish_default") }, ...(this.endsValue || []).filter(e => e.id !== "default") ]
    ends.forEach(e => {
      const flag = document.createElement("div")
      flag.className = `j-flag${e.id === "default" ? "" : " j-flag-alt"}`
      flag.dataset.dropTarget = `end:${e.id}`
      flag.textContent = `🏁 ${e.title || e.id}`
      this._nodeByKey.set(`end:${e.id}`, flag)
      flagRow.appendChild(flag)
    })
    canvas.appendChild(flagRow)

    // Wires are measured after layout settles (clone heights included).
    requestAnimationFrame(() => { this._sizeClones(); this._wire(cards, flows, scroll, svg) })
  }

  // A real, sanitised, scaled clone of the card — the same picture of
  // design + question + options the creator sees in the feed.
  _cardNode(card, cards, flow) {
    const node = document.createElement("div")
    node.className = `j-node${flow ? " j-member" : ""}`
    node.dataset.cid = card.cid || ""
    node.dataset.dropTarget = flow ? `flow:${flow.id}` : `card:${card.cid}`
    if (flow) node.style.setProperty("--flow-color", flow.color)
    this._nodeByKey.set(`card:${card.cid}`, node)

    const holder = document.createElement("div")
    holder.className = "j-clone"
    const inner = document.createElement("div")
    inner.className = "j-clone-inner"
    const clone = this._cloneCard(card.cid)
    if (clone) inner.appendChild(clone)
    else {
      const fb = document.createElement("div")
      fb.className = "j-fallback"
      fb.textContent = (card.text || "…").slice(0, 80)
      inner.appendChild(fb)
    }
    holder.appendChild(inner)
    node.appendChild(holder)

    const cap = document.createElement("div")
    cap.className = "j-caption"
    const idx = cards.findIndex(c => c.cid === card.cid)
    cap.textContent = `Card ${idx + 1}`
    node.appendChild(cap)

    // Routable questions grow an answer-chip strip — the drag sources.
    const routes = new Map()
    ;((card.logic && card.logic.routes) || []).forEach(r => {
      if (r?.match?.value != null && r.to) routes.set(String(r.match.value), r.to)
    })
    const routable = [ "multiple_choice", "yes_no", "scenario" ].includes(card.type)
    if (routable && Array.isArray(card.options) && card.options.length) {
      node.appendChild(this._answerStrip(card, cards, routes))
    }
    holder.addEventListener("click", () => this._jumpTo(card.cid))
    return node
  }

  _answerStrip(card, cards, routes) {
    const strip = document.createElement("div")
    strip.className = "j-answers"
    const editor = this._editor()
    const flowOfCid = new Map()
    editor.serialize().cards.forEach(c => { if (c.flow_id && c.cid) flowOfCid.set(c.cid, c.flow_id) })
    const chipFor = (label, canonical, isDefault) => {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = "j-chip"
      chip.dataset.qcid = card.cid
      if (isDefault) chip.dataset.default = "true"
      else chip.dataset.canonical = canonical
      const to = isDefault ? (card.logic && card.logic.default) : routes.get(canonical)
      let color = null
      if (to?.card) {
        const fid = flowOfCid.get(to.card)
        color = fid ? (editor.flowById(fid)?.color || "#8B85FF") : "#0CA7FF"
      } else if (to?.end) color = "#01EACB"
      const dot = document.createElement("span")
      dot.className = "j-dot"
      dot.style.background = color || "rgba(255,255,255,0.25)"
      if (color) dot.style.boxShadow = `0 0 6px ${color}`
      chip.append(dot, document.createTextNode(label))
      chip.dataset.routed = color ? "true" : "false"
      if (this.editableValue) this._makeChipDraggable(chip)
      strip.appendChild(chip)
      return chip
    }
    card.options.forEach(o => chipFor(o, String(o), false))
    chipFor(t("editor.flows.entry_otherwise"), null, true)
    return strip
  }

  _stackNode(run, key, cards) {
    const node = document.createElement("div")
    node.className = "j-node j-stackwrap"
    const holder = document.createElement("div")
    holder.className = "j-clone j-stacked"
    const inner = document.createElement("div")
    inner.className = "j-clone-inner"
    const clone = this._cloneCard(run[0].cid)
    if (clone) inner.appendChild(clone)
    holder.appendChild(inner)
    node.appendChild(holder)
    const from = cards.findIndex(c => c.cid === run[0].cid) + 1
    const cap = document.createElement("button")
    cap.type = "button"
    cap.className = "j-caption j-stack-cap"
    cap.textContent = `${t("editor.flows.stack_label", { from, to: from + run.length - 1 })} · ${t("editor.flows.stack_hint")}`
    cap.addEventListener("click", () => { this._expanded.add(key); this._render() })
    holder.addEventListener("click", () => { this._expanded.add(key); this._render() })
    node.appendChild(cap)
    this._nodeByKey.set(`card:${run[0].cid}`, node)
    run.slice(1).forEach(c => this._nodeByKey.set(`card:${c.cid}`, node))
    return node
  }

  _colsRow(flowsHere, cards, flowById, orphan) {
    const row = document.createElement("div")
    row.className = "j-cols"
    flowsHere.forEach(flow => {
      const col = document.createElement("div")
      col.className = "j-col"
      col.style.setProperty("--flow-color", flow.color)
      col.dataset.dropTarget = `flow:${flow.id}`
      const members = cards.filter(c => c.flow_id === flow.id)
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = "j-lanechip"
      chip.dataset.flowId = flow.id
      chip.textContent = `⎇ ${orphan ? "⚠ " : ""}${flow.name}`
      const count = document.createElement("span")
      count.className = "j-lanecount"
      count.textContent = t("editor.flows.header_count", { count: members.length })
      chip.appendChild(count)
      if (this.editableValue) chip.addEventListener("click", () => {
        const name = window.prompt(t("editor.flows.name_prompt"), flow.name)
        if (name != null) { this._editor()?.renameFlow(flow.id, name); this._render() }
      })
      this._nodeByKey.set(`flow:${flow.id}`, chip)
      col.appendChild(chip)
      members.forEach(m => col.appendChild(this._cardNode(m, cards, flow)))
      if (this.editableValue) {
        const ghost = document.createElement("div")
        ghost.className = "j-ghost"
        const add = document.createElement("button")
        add.type = "button"
        add.textContent = t("editor.flows.add_card")
        add.addEventListener("click", async () => { await this._flows()?.addCardToFlow(flow.id); this._render() })
        const gen = document.createElement("button")
        gen.type = "button"
        gen.textContent = `✨ ${t("editor.flows.generate_short")}`
        gen.addEventListener("click", () => this._flows()?.openGenerate())
        ghost.append(add, gen)
        col.appendChild(ghost)
        // The exit handle: drag "then →" onto a card, flow or flag to set
        // where this flow goes when its cards run out.
        const exit = document.createElement("button")
        exit.type = "button"
        exit.className = "j-exit"
        exit.dataset.flowId = flow.id
        exit.textContent = `${t("editor.flows.exit_label")} ⇢`
        this._makeExitDraggable(exit)
        col.appendChild(exit)
      }
      row.appendChild(col)
    })
    return row
  }

  // Reserve layout space for each scaled clone (offsetHeight is measured on
  // the unscaled inner, then the holder takes the scaled height).
  _sizeClones() {
    this._overlay.querySelectorAll(".j-clone").forEach(holder => {
      const inner = holder.querySelector(".j-clone-inner")
      if (!inner) return
      const natural = inner.dataset.naturalW ? Number(inner.dataset.naturalW) : 720
      const scale = CARD_W / natural
      inner.style.width = `${natural}px`
      inner.style.transform = `scale(${scale})`
      inner.style.transformOrigin = "top left"
      holder.style.width = `${CARD_W}px`
      holder.style.height = `${Math.max(60, inner.offsetHeight * scale)}px`
    })
  }

  _cloneCard(cid) {
    const src = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(cid)}"] .split-card`)
    if (!src) return null
    const clone = src.cloneNode(true)
    clone.querySelectorAll(".logic-branch-block, [data-role='move-up'], [data-role='move-down'], .card-delete-btn, .card-duplicate-btn, .quiz-correct-block, .token-award-block").forEach(el => el.remove())
    ;[ clone, ...clone.querySelectorAll("*") ].forEach(el => {
      el.removeAttribute("data-controller"); el.removeAttribute("data-action")
      el.removeAttribute("contenteditable"); el.removeAttribute("id"); el.removeAttribute("name")
      el.removeAttribute("tabindex")
    })
    const wrap = src.closest(".survey-card-wrap")
    const holderStyle = getComputedStyle(wrap)
    const inner = document.createElement("div")
    ;[ "--brand-primary", "--brand-cta", "--brand-bg", "--brand-bg-image", "--brand-cta-text", "--brand-primary-text", "--brand-secondary" ]
      .forEach(v => { const val = holderStyle.getPropertyValue(v); if (val && val.trim()) inner.style.setProperty(v, val.trim()) })
    inner.appendChild(clone)
    const naturalW = wrap.offsetWidth || 720
    inner.dataset.naturalW = String(naturalW > 0 ? naturalW : 720)
    return inner
  }

  // ── Wires ────────────────────────────────────────────────────────────────

  _wire(cards, flows, scroll, svg) {
    svg.textContent = ""
    const canvas = this._overlay.querySelector("[data-journey-target='canvas']")
    svg.setAttribute("width", scroll.clientWidth)
    svg.setAttribute("height", Math.max(scroll.scrollHeight, canvas.scrollHeight))
    const origin = scroll.getBoundingClientRect()
    const pt = (el, side) => {
      const r = el.getBoundingClientRect()
      const x = r.left - origin.left + scroll.scrollLeft
      const y = r.top - origin.top + scroll.scrollTop
      if (side === "b") return [ x + r.width / 2, y + r.height ]
      if (side === "t") return [ x + r.width / 2, y ]
      return [ x + r.width / 2, y + r.height / 2 ]
    }
    const draw = (a, b, color, opts = {}) => {
      if (!a || !b) return null
      const [ x1, y1 ] = a, [ x2, y2 ] = b
      const my = (y1 + y2) / 2
      const p = document.createElementNS("http://www.w3.org/2000/svg", "path")
      p.setAttribute("d", `M ${x1} ${y1} C ${x1} ${my}, ${x2} ${my}, ${x2} ${y2}`)
      p.setAttribute("stroke", color)
      p.setAttribute("stroke-width", opts.width || 2.5)
      p.setAttribute("fill", "none")
      p.setAttribute("stroke-linecap", "round")
      if (opts.dash) p.setAttribute("stroke-dasharray", "5 6")
      svg.appendChild(p)
      return p
    }
    const node = key => this._nodeByKey.get(key)
    const flowOfCid = new Map()
    cards.forEach(c => { if (c.flow_id && c.cid) flowOfCid.set(c.cid, c.flow_id) })
    const targetKey = to => {
      if (!to) return null
      if (to.end != null && String(to.end) !== "") return `end:${to.end}`
      if (to.card) { const f = flowOfCid.get(to.card); return f ? `flow:${f}` : `card:${to.card}` }
      return null
    }

    // Spine thread: consecutive rendered spine nodes (stacks count once).
    const spineEls = []
    this._overlay.querySelectorAll(".journey-canvas > .j-node:not(.j-member)").forEach(el => spineEls.push(el))
    for (let i = 0; i < spineEls.length - 1; i++) {
      draw(pt(spineEls[i], "b"), pt(spineEls[i + 1], "t"), "rgba(244,246,255,0.28)")
    }
    if (spineEls.length) draw(pt(spineEls[spineEls.length - 1], "b"), pt(node("end:default"), "t"), "rgba(244,246,255,0.28)")

    // Answer routes: chip → its target (flow chip, spine card or flag).
    this._overlay.querySelectorAll(".j-chip").forEach(chip => {
      const qcid = chip.dataset.qcid
      const card = cards.find(c => c.cid === qcid)
      if (!card) return
      const to = chip.dataset.default === "true"
        ? (card.logic && card.logic.default)
        : ((card.logic?.routes || []).find(r => String(r?.match?.value) === chip.dataset.canonical)?.to)
      const key = targetKey(to)
      if (!key) return
      const color = getComputedStyle(chip.querySelector(".j-dot")).backgroundColor
      const p = draw(pt(chip, "b"), pt(node(key), "t"), color, { dash: chip.dataset.default === "true" })
      if (p && this.editableValue) {
        p.classList.add("j-wire-clickable")
        p.addEventListener("click", () => this._clearRoute(qcid, chip))
        const title = document.createElementNS("http://www.w3.org/2000/svg", "title")
        title.textContent = t("editor.flows.wire_clear")
        p.appendChild(title)
      }
    })

    // Flow chains + exits.
    flows.forEach(flow => {
      const members = cards.filter(c => c.flow_id === flow.id)
      if (!members.length) return
      const els = [ node(`flow:${flow.id}`), ...members.map(m => this._nodeByKey.get(`card:${m.cid}`)) ].filter(Boolean)
      for (let i = 0; i < els.length - 1; i++) draw(pt(els[i], "b"), pt(els[i + 1], "t"), flow.color)
      const exitKey = targetKey(flow.exit && (flow.exit.flow ? { card: cards.find(c => c.flow_id === flow.exit.flow)?.cid } : flow.exit))
      const last = els[els.length - 1]
      const exitHandle = this._overlay.querySelector(`.j-exit[data-flow-id="${CSS.escape(flow.id)}"]`)
      const from = exitHandle || last
      if (exitKey && node(exitKey)) draw(pt(from, "b"), pt(node(exitKey), "t"), flow.color)
      else draw(pt(from, "b"), pt(node("end:default"), "t"), flow.color, { dash: true, width: 2 })
    })
  }

  // ── Editing ──────────────────────────────────────────────────────────────

  _makeChipDraggable(chip) {
    chip.addEventListener("pointerdown", (e) => {
      e.preventDefault()
      this._drag = { chip, x: e.clientX, y: e.clientY }
      const up = (ev) => {
        window.removeEventListener("pointerup", up)
        const moved = Math.hypot(ev.clientX - this._drag.x, ev.clientY - this._drag.y)
        const dropEl = document.elementFromPoint(ev.clientX, ev.clientY)
        this._drag = null
        if (moved < 14) return // a plain click: chips aren't buttons to press
        this._dropRoute(chip, dropEl)
      }
      window.addEventListener("pointerup", up)
    })
  }

  _makeExitDraggable(handle) {
    handle.addEventListener("pointerdown", (e) => {
      e.preventDefault()
      const x = e.clientX, y = e.clientY
      const up = (ev) => {
        window.removeEventListener("pointerup", up)
        if (Math.hypot(ev.clientX - x, ev.clientY - y) < 14) return
        const dropEl = document.elementFromPoint(ev.clientX, ev.clientY)
        const target = dropEl?.closest?.("[data-drop-target]")
        if (!target) return
        const [ kind, id ] = target.dataset.dropTarget.split(":")
        const editor = this._editor()
        if (kind === "end") editor.setFlowExit(handle.dataset.flowId, { end: id })
        else if (kind === "flow" && id !== handle.dataset.flowId) editor.setFlowExit(handle.dataset.flowId, { flow: id })
        else if (kind === "card") editor.setFlowExit(handle.dataset.flowId, { card: id })
        this._render()
      }
      window.addEventListener("pointerup", up)
    })
  }

  _dropRoute(chip, dropEl) {
    const editor = this._editor()
    const sel = this._selFor(chip)
    if (!editor || !sel) return
    const target = dropEl?.closest?.("[data-drop-target]")
    if (!target) {
      // Dropped on empty canvas: a per-answer chip starts a NEW flow there.
      if (chip.dataset.default !== "true" && dropEl?.closest?.("[data-journey-target='canvas'], [data-journey-target='scroll']")) {
        this._flows()?.createFromRouteSelect(sel)?.then?.(() => this._render())
        setTimeout(() => this._render(), 600)
      }
      return
    }
    const value = target.dataset.dropTarget // "flow:x" | "card:x" | "end:x"
    sel.dataset.logicSelected = value
    editor.refreshLogicTargets()
    editor.markDirty()
    this._render()
  }

  _clearRoute(qcid, chip) {
    const sel = this._selFor(chip)
    if (!sel) return
    sel.dataset.logicSelected = ""
    const editor = this._editor()
    editor.refreshLogicTargets()
    editor.markDirty()
    this._render()
  }

  _selFor(chip) {
    const scope = this._editor()?.logicScopeForCid?.(chip.dataset.qcid)
    if (!scope) return null
    return chip.dataset.default === "true"
      ? scope.querySelector("[data-logic-default]")
      : scope.querySelector(`[data-logic-route][data-canonical="${CSS.escape(chip.dataset.canonical)}"]`)
  }

  _jumpTo(cid) {
    this.close()
    const el = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(cid)}"]`)
    if (!el) return
    this._editor()?.focusFlowForCard?.(el)
    el.scrollIntoView({ behavior: "smooth", block: "center" })
    el.click()
    el.classList.add("card-flash")
    setTimeout(() => el.classList.remove("card-flash"), 1200)
  }

  // ── Wiring to the other editor controllers (one-root pattern) ────────────

  _root() { return document.querySelector("[data-survey-editor-url-value]") }
  _editor() {
    const el = this._root()
    return el ? this.application.getControllerForElementAndIdentifier(el, "survey-editor") : null
  }
  _flows() {
    const el = this._root()
    return el ? this.application.getControllerForElementAndIdentifier(el, "flows") : null
  }
}
