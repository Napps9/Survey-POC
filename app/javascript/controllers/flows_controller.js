import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { computeWarnings } from "lib/graph_warnings"
import { computeLanes } from "lib/flow_lanes"

// The Flows panel: lists the deck's first-class flows (name, colour, entry,
// exit, member count), creates/renames/deletes them, and surfaces wiring
// warnings. Declared on the editor ROOT alongside survey-editor (the
// established one-root pattern), with its targets living inside the Logic &
// flows panel partial (surveys/_flow_panel).
//
// All flow STATE lives in survey-editor (the working set serialize() sends);
// this controller is a view over it plus thin action handlers. It repaints on
// survey-editor:refreshed (dispatched from refreshAll on every structural
// change) and must stay render-only on that path — mutating or markDirty-ing
// from a repaint would loop.
export default class extends Controller {
  static targets = [ "list", "warnings", "legacy",
    "modal", "generateStep", "generateSpinner", "generatePrompt", "generateAnswer", "generateError" ]
  static values = { generateUrl: { type: String, default: "" } }

  connect() {
    // survey-editor may not have connected yet (same element, order not
    // guaranteed) — defer the first paint a frame.
    requestAnimationFrame(() => this.repaint())
    // Staleness counter for the generate modal (add-question's idiom): a
    // response whose token no longer matches was superseded — drop it.
    this._requestToken = 0
  }

  repaint() {
    if (!this.hasListTarget) return
    const editor = this._editor()
    if (!editor || typeof editor.flowsList !== "function") return
    const { cards, flows } = editor.serialize()
    this._renderList(editor)
    this._renderLegacyLanes(editor, cards)
    this._renderWarnings(editor, cards, flows)
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  newFlow() {
    const name = (prompt(t("editor.flows.name_prompt")) || "").trim()
    if (!name) return
    this._editor()?.addFlow({ name })
  }

  // The "+ New flow from this answer…" action on a route select: create a
  // flow named after the answer with one starter card spliced right below the
  // question, wire the answer to it, and pin the question's "otherwise" to
  // where its other answers were already going (splicing directly below would
  // otherwise silently reroute them through the new flow — same trap the flow
  // map's _createBranchCard pins).
  async createFromRouteSelect(sel) {
    const editor = this._editor()
    if (!editor || editor.liveValue) return
    const ownerCid = sel.closest("[data-survey-editor-target='card']")?.dataset.cardCid
                  || sel.closest("[data-logic-block]")?.dataset.ownerCid
    const ownerWrap = ownerCid &&
      this.element.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(ownerCid)}"]`)
    if (!ownerWrap) return

    const flow = editor.addFlow({ name: sel.dataset.canonical || "" })
    const ownerSlot = ownerWrap.closest(".card-slot")
    const continuation = this._continuationAfter(ownerSlot)
    const card = await this._spliceCard({ type: "open_ended", text: "", flow_id: flow.id }, ownerSlot, flow.id)
    if (!card) { editor.removeFlow(flow.id); return }

    // Pin the otherwise before the new card becomes the linear fall-through.
    const defSel = editor.logicScopeForCid?.(ownerCid)?.querySelector("[data-logic-default]")
    if (defSel && !(defSel.dataset.logicSelected || "")) {
      defSel.dataset.logicSelected = continuation
    }
    sel.dataset.logicSelected = `flow:${flow.id}`
    editor.refreshAll()
    editor.markDirty()
  }

  // ── Generate a flow with AI ──────────────────────────────────────────────

  openGenerate() {
    const editor = this._editor()
    if (!this.hasModalTarget || !editor || editor.liveValue) return
    this._fillAnswerOptions(editor)
    this.generateErrorTarget.style.display = "none"
    this.generateStepTarget.hidden = false
    this.generateSpinnerTarget.hidden = true
    this.modalTarget.hidden = false
    this.generatePromptTarget.focus()
  }

  closeGenerate() {
    this._requestToken++
    if (this.hasModalTarget) this.modalTarget.hidden = true
  }

  backdropClick(event) {
    if (event.target === this.modalTarget) this.closeGenerate()
  }

  // Currently-unrouted single-pick answers the generated flow can be wired to.
  _fillAnswerOptions(editor) {
    const sel = this.generateAnswerTarget
    sel.innerHTML = ""
    sel.appendChild(this._option("", t("editor.flows.wire_none")))
    this.element.querySelectorAll("[data-logic-route]").forEach(rs => {
      if (rs.dataset.logicSelected || !rs.dataset.canonical) return
      const ownerCid = rs.closest("[data-survey-editor-target='card']")?.dataset.cardCid
                    || rs.closest("[data-logic-block]")?.dataset.ownerCid
      if (!ownerCid) return
      const wrap = this.element.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(ownerCid)}"]`)
      const label = t("editor.flows.entry_from", { card: wrap?.dataset.cardNum || "?", answer: rs.dataset.canonical })
      sel.appendChild(this._option(JSON.stringify([ ownerCid, rs.dataset.canonical ]), label))
    })
  }

  async submitGenerate() {
    const editor = this._editor()
    if (!editor || editor.liveValue) return
    const prompt = (this.generatePromptTarget.value || "").trim()
    if (!prompt) {
      this.generateErrorTarget.textContent = t("editor.flows.prompt_needed")
      this.generateErrorTarget.style.display = ""
      return
    }
    let wire = null
    try { wire = this.generateAnswerTarget.value ? JSON.parse(this.generateAnswerTarget.value) : null } catch (_) {}
    const ownerWrap = wire &&
      this.element.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(wire[0])}"]`)
    const entryText = ownerWrap?.querySelector(".q-title, .activity-title")?.textContent?.trim() || null

    const token = ++this._requestToken
    this.generateStepTarget.hidden = true
    this.generateSpinnerTarget.hidden = false
    try {
      const res = await fetch(this.generateUrlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify({ prompt, answer: wire ? wire[1] : null, entry_text: entryText })
      })
      const json = await res.json()
      if (!json || !json.ok) throw new Error((json && json.error) || "Generation failed")
      if (token !== this._requestToken) return // modal closed/reopened — drop it

      const flow = editor.addFlow({ name: json.name || (wire ? wire[1] : "") })
      // Splice the generated cards right below the entry question (or at the
      // feed end when unanchored), capturing the pre-splice continuation so
      // the question's other answers keep their path.
      let afterSlot = ownerWrap?.closest(".card-slot") || null
      const continuation = ownerWrap ? this._continuationAfter(afterSlot) : null
      ;(json.cards || []).forEach(item => {
        const card = this._spliceHTML(item.html, afterSlot, flow.id)
        if (card) afterSlot = card.closest(".card-slot")
      })
      if (wire && ownerWrap) {
        const scope = editor.logicScopeForCid?.(wire[0])
        const rs = scope?.querySelector(`[data-logic-route][data-canonical="${CSS.escape(wire[1])}"]`)
        if (rs) rs.dataset.logicSelected = `flow:${flow.id}`
        const defSel = scope?.querySelector("[data-logic-default]")
        if (defSel && !defSel.dataset.logicSelected && continuation) defSel.dataset.logicSelected = continuation
      }
      editor.refreshAll()
      editor.markDirty()
      this.closeGenerate()
      editor.flowMemberWraps(flow.id)[0]?.scrollIntoView({ behavior: "smooth", block: "center" })
    } catch (err) {
      if (token !== this._requestToken) return
      this.generateSpinnerTarget.hidden = true
      this.generateStepTarget.hidden = false
      this.generateErrorTarget.textContent = t("editor.flows.generate_failed", { msg: err.message })
      this.generateErrorTarget.style.display = ""
    }
  }

  // ── Rendering ────────────────────────────────────────────────────────────

  _renderList(editor) {
    const flows = editor.flowsList()
    const list = this.listTarget
    list.textContent = ""
    if (!flows.length) {
      const empty = document.createElement("div")
      empty.className = "flow-list-empty"
      empty.textContent = t("editor.flows.no_flows")
      list.appendChild(empty)
      return
    }
    const inbound = this._inboundByFlow()
    flows.forEach(flow => list.appendChild(this._flowCard(editor, flow, inbound.get(flow.id) || [])))
  }

  _flowCard(editor, flow, inbound) {
    const editable = !editor.liveValue
    const members = editor.flowMemberWraps(flow.id)
    const card = document.createElement("div")
    card.className = "flow-card"
    card.style.setProperty("--flow-color", flow.color)
    card.dataset.flowId = flow.id

    // Head: colour dot + name + member count
    const head = document.createElement("div")
    head.className = "flow-card-head"
    const dot = document.createElement("span")
    dot.className = "flow-header-dot"
    dot.setAttribute("aria-hidden", "true")
    const name = document.createElement("input")
    name.className = "flow-name-input"
    name.type = "text"
    name.maxLength = 60
    name.value = flow.name
    name.disabled = !editable
    name.setAttribute("aria-label", t("editor.flows.name_prompt"))
    name.addEventListener("change", () => this._editor()?.renameFlow(flow.id, name.value))
    name.addEventListener("keydown", e => { if (e.key === "Enter") name.blur() })
    const count = document.createElement("span")
    count.className = "flow-header-count"
    count.textContent = t("editor.flows.header_count", { count: members.length })
    head.append(dot, name, count)
    card.appendChild(head)

    // Entry: which answer(s) open this flow
    const entry = document.createElement("div")
    entry.className = "flow-card-entry"
    if (inbound.length) {
      const first = inbound[0]
      const extra = inbound.length > 1 ? ` +${inbound.length - 1}` : ""
      entry.textContent = `← ${first.label}${extra}`
    } else {
      entry.textContent = `⚠ ${t("editor.flows.entry_none")}`
      entry.classList.add("is-warn")
    }
    card.appendChild(entry)

    // Exit: where the flow goes when its cards run out
    const exitRow = document.createElement("div")
    exitRow.className = "flow-card-exit"
    const exitLabel = document.createElement("span")
    exitLabel.textContent = t("editor.flows.exit_label")
    const exitSel = this._exitSelect(editor, flow)
    exitSel.disabled = !editable
    exitRow.append(exitLabel, exitSel)
    card.appendChild(exitRow)

    // Actions
    if (editable) {
      const actions = document.createElement("div")
      actions.className = "flow-card-actions"
      if (members.length) actions.appendChild(this._actionBtn(t("editor.flows.jump"), () => {
        members[0].scrollIntoView({ behavior: "smooth", block: "center" })
      }))
      actions.appendChild(this._actionBtn(t("editor.flows.add_card"), () => this.addCardToFlow(flow.id)))
      actions.appendChild(this._armedBtn(t("editor.flows.dissolve"), () => {
        this._editor()?.removeFlow(flow.id, { deleteCards: false })
      }))
      if (members.length) actions.appendChild(this._armedBtn(t("editor.flows.delete_cards"), () => {
        this._editor()?.removeFlow(flow.id, { deleteCards: true })
      }, "flow-action-danger"))
      card.appendChild(actions)
    }
    return card
  }

  // Options mirror the route selects' vocabulary: continue linearly, finish
  // on an end screen, chain into another flow, or converge on a card outside
  // any flow. Values encode as "" | "end:<id>" | "flow:<id>" | "card:<cid>".
  _exitSelect(editor, flow) {
    const sel = document.createElement("select")
    sel.className = "logic-route-select flow-exit-select"
    sel.appendChild(this._option("", t("editor.flows.exit_continue")))
    const cfg = editor.logicConfigValue || {}
    const flows = editor.flowsList().filter(f => f.id !== flow.id)
    if (flows.length) {
      const group = document.createElement("optgroup")
      group.label = t("editor.flows.group")
      flows.forEach(f => group.appendChild(this._option(`flow:${f.id}`, t("editor.flows.option", { name: f.name }))))
      sel.appendChild(group)
    }
    ;(Array.isArray(cfg.ends) ? cfg.ends : []).forEach(e =>
      sel.appendChild(this._option(`end:${e.id}`, `${cfg.finishPrefix || "Finish"} · ${e.label}`)))
    editor.cardTargets.forEach(c => {
      const cid = c.dataset.cardCid
      if (!cid || c.dataset.cardFlowId) return
      const label = (c.querySelector(".q-title, .activity-title")?.textContent || "").trim().slice(0, 40)
      sel.appendChild(this._option(`card:${cid}`, label ? `→ Card ${c.dataset.cardNum}: ${label}` : `→ Card ${c.dataset.cardNum}`))
    })
    const ex = flow.exit || {}
    sel.value = ex.end ? `end:${ex.end}` : ex.flow ? `flow:${ex.flow}` : ex.card ? `card:${ex.card}` : ""
    if (sel.value === "" && (ex.end || ex.flow || ex.card)) sel.value = "" // target gone ⇒ continue
    sel.addEventListener("change", () => {
      const v = sel.value
      const target = v.startsWith("end:")  ? { end: v.slice(4) }
                   : v.startsWith("flow:") ? { flow: v.slice(5) }
                   : v.startsWith("card:") ? { card: v.slice(5) }
                   : null
      this._editor()?.setFlowExit(flow.id, target)
    })
    return sel
  }

  // Hand-wired branches (derived lanes) not yet covered by a flow, each with a
  // one-click upgrade. Only SIMPLE lanes (a plain chain) convert — a lane with
  // sub-branches keeps its wiring untouched.
  _renderLegacyLanes(editor, cards) {
    if (!this.hasLegacyTarget) return
    const box = this.legacyTarget
    box.textContent = ""
    if (editor.liveValue) { box.style.display = "none"; return }
    const claimed = new Set(cards.filter(c => c.flow_id).map(c => c.cid))
    const lanes = computeLanes(cards).filter(l => l.simple && !claimed.has(l.entry))
    box.style.display = lanes.length ? "" : "none"
    if (!lanes.length) return
    const title = document.createElement("div")
    title.className = "flow-legacy-title"
    title.textContent = t("editor.flows.legacy_title")
    box.appendChild(title)
    lanes.forEach(lane => {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = "flow-legacy-chip"
      chip.textContent = `⎇ ${lane.label} — ${t("editor.flows.convert")}`
      chip.addEventListener("click", () => this._convertLane(lane))
      box.appendChild(chip)
    })
  }

  // Upgrade a derived lane to a first-class flow: same name, exit = the lane's
  // rejoin target, membership = its spine. The inbound answer route already
  // points at the entry card, so refreshLogicTargets upgrades it to flow:<id>
  // on the next repaint; the entry's lane_label is superseded and cleared.
  _convertLane(lane) {
    const editor = this._editor()
    if (!editor || editor.liveValue) return
    const exit = lane.rejoin.startsWith("card:") ? { card: lane.rejoin.slice(5) }
               : lane.rejoin.startsWith("end:")  ? { end: lane.rejoin.slice(4) }
               : null
    const flow = editor.addFlow({ name: lane.label, exit })
    lane.spine.forEach(cid => {
      const wrap = this.element.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(cid)}"]`)
      if (!wrap) return
      wrap.dataset.cardFlowId = flow.id
      delete wrap.dataset.cardLaneLabel
    })
    editor.refreshAll()
    editor.markDirty()
  }

  _renderWarnings(editor, cards, flows) {
    if (!this.hasWarningsTarget) return
    const box = this.warningsTarget
    const endIds = [ "default", ...((editor.logicConfigValue?.ends || []).map(e => e.id)) ]
    const warnings = computeWarnings(cards, flows, endIds)
    box.textContent = ""
    box.style.display = warnings.length ? "" : "none"
    const nameOf = id => editor.flowById(id)?.name || id
    warnings.forEach(w => {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = "flow-warn-chip"
      if (w.kind === "dangling")          chip.textContent = t("editor.flows.warn_dangling", { n: w.num })
      else if (w.kind === "self_loop")    chip.textContent = t("editor.flows.warn_self", { n: w.num })
      else if (w.kind === "empty_flow")   chip.textContent = t("editor.flows.warn_empty", { name: nameOf(w.flowId) })
      else if (w.kind === "unreachable_flow") chip.textContent = t("editor.flows.warn_unreachable", { name: nameOf(w.flowId) })
      else if (w.kind === "flow_cycle")   chip.textContent = t("editor.flows.warn_cycle", { names: w.flowIds.map(nameOf).join(" → ") })
      else return
      chip.addEventListener("click", () => this._jumpToWarning(w))
      box.appendChild(chip)
    })
  }

  _jumpToWarning(w) {
    const editor = this._editor()
    if (!editor) return
    let el = null
    if (w.num != null) el = editor.cardTargets[w.num - 1]
    else if (w.flowId) el = editor.flowMemberWraps(w.flowId)[0]
    else if (w.flowIds?.length) el = editor.flowMemberWraps(w.flowIds[0])[0]
    el?.scrollIntoView({ behavior: "smooth", block: "center" })
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  _editor() {
    return this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")
  }

  // Route selects currently sending an answer into each flow, for the entry
  // readout: [{ label: "Card 2 · UK" }]. Scans the live selects (wherever the
  // relocation machinery has them) rather than serialized data so it matches
  // what the creator just picked, saved or not.
  _inboundByFlow() {
    const map = new Map()
    this.element.querySelectorAll("[data-logic-route], [data-logic-default]").forEach(sel => {
      const chosen = sel.dataset.logicSelected || ""
      if (!chosen.startsWith("flow:")) return
      const flowId = chosen.slice(5)
      const ownerCid = sel.closest("[data-survey-editor-target='card']")?.dataset.cardCid
                    || sel.closest("[data-logic-block]")?.dataset.ownerCid
      const ownerWrap = ownerCid &&
        this.element.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(ownerCid)}"]`)
      const cardNum = ownerWrap?.dataset.cardNum
      const answer = sel.hasAttribute("data-logic-route")
        ? (sel.dataset.canonical || "")
        : t("editor.flows.entry_otherwise")
      const label = t("editor.flows.entry_from", { card: cardNum || "?", answer })
      if (!map.has(flowId)) map.set(flowId, [])
      map.get(flowId).push({ label })
    })
    return map
  }

  // Where the deck currently continues after `slot` — the next slot's card
  // (encoded "card:<cid>") or the finish. Captured BEFORE splicing a new card
  // in, to pin a question's "otherwise" route.
  _continuationAfter(slot) {
    let el = slot?.nextElementSibling
    while (el && !el.classList.contains("card-slot")) el = el.nextElementSibling
    const cid = el?.querySelector("[data-survey-editor-target='card']")?.dataset.cardCid
    return cid ? `card:${cid}` : "end:default"
  }

  // Append a blank card to a flow. Public: the flow map's lane-chip "+" calls
  // it too, so both surfaces share one splice path.
  async addCardToFlow(flowId) {
    const editor = this._editor()
    if (!editor || editor.liveValue) return
    const members = editor.flowMemberWraps(flowId)
    const afterSlot = members.length ? members[members.length - 1].closest(".card-slot") : null
    const card = await this._spliceCard({ type: "open_ended", text: "", flow_id: flowId }, afterSlot, flowId)
    if (!card) return
    editor.refreshAll()
    editor.markDirty()
    card.scrollIntoView({ behavior: "smooth", block: "center" })
  }

  // POST a card JSON to render_card and splice the returned row into the feed.
  // The server stamps the cid; autosave persists the deck.
  async _spliceCard(cardJson, afterSlot, flowId) {
    const url = this.element.dataset.addQuestionRenderUrlValue
    if (!url) return null
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify(cardJson)
      })
      const json = await res.json()
      if (!json || !json.ok) return null
      return this._spliceHTML(json.html, afterSlot, flowId)
    } catch (_) {
      return null
    }
  }

  // Wrap a server-rendered card row in a slot and splice it into the feed
  // (after `afterSlot`, else at the end), tagged with the flow. Mirrors
  // add_question's _insertHTML / the flow map's _createBranchCard splice.
  _spliceHTML(html, afterSlot, flowId) {
    const feed = this.element.querySelector("[data-add-question-target='cardsFeed']")
    if (!feed) return null
    const tmp = document.createElement("div")
    tmp.innerHTML = (html || "").trim()
    const card = tmp.firstElementChild
    if (!card) return null
    const slot = document.createElement("div")
    slot.className = "card-slot"
    slot.appendChild(card)
    const insertRow = feed.querySelector(".aq-insert-row")
    if (insertRow) slot.appendChild(insertRow.cloneNode(true))
    if (afterSlot && afterSlot.parentNode === feed) afterSlot.after(slot)
    else feed.appendChild(slot)
    if (flowId) card.dataset.cardFlowId = flowId
    this.application.getControllerForElementAndIdentifier(this.element, "type-panel")?.registerCard(card)
    return card
  }

  _option(value, label) {
    const o = document.createElement("option")
    o.value = value
    o.textContent = label
    return o
  }

  _actionBtn(label, onClick, extraClass) {
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = `flow-action-btn${extraClass ? ` ${extraClass}` : ""}`
    btn.textContent = label
    btn.addEventListener("click", onClick)
    return btn
  }

  // Two-tap confirm, matching the feed's delete button idiom: first click
  // arms (label swaps to a confirm), second within 3s fires, timeout resets.
  _armedBtn(label, onConfirm, extraClass) {
    const btn = this._actionBtn(label, () => {
      if (btn.dataset.armed === "true") {
        clearTimeout(this._armTimer)
        onConfirm()
        return
      }
      btn.dataset.armed = "true"
      btn.textContent = t("editor.flows.confirm")
      btn.classList.add("is-armed")
      clearTimeout(this._armTimer)
      this._armTimer = setTimeout(() => {
        btn.dataset.armed = "false"
        btn.textContent = label
        btn.classList.remove("is-armed")
      }, 3000)
    }, extraClass)
    return btn
  }
}
