import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { haptic } from "lib/haptics"

const MAP_MIN_SCALE = 1
const MAP_MAX_SCALE = 8

// Cards that ask for agreement rather than an answer, and drive their own
// navigation. "consent_card" is the survey-level gate rendered as a pseudo-card
// before the deck (from consent_text); "consent_gate" is the multi-page card
// type a creator can place and reorder like any other. A Verto has one or the
// other — Survey#consent_required? goes false once a consent_gate card exists,
// so the pseudo-card stops rendering rather than stacking two gates.
const CONSENT_TYPES = [ "consent_card", "consent_gate" ]

export default class extends Controller {
  static targets = ["card", "backBtn", "nextBtn", "finishBtn", "thankyou", "progress",
                    "thankyouMain", "thankyouTitle", "thankyouSub", "forwardBtn", "compareBtn", "comparePanel",
                    "scoresSection", "comparisonSection",
                    "comparisonList", "comparisonMeta",
                    "regionsBtn", "regionsPanel", "regionsMain", "regionsMeta", "regionsList",
                    "regionsMapViewport", "regionsMapStage",
                    "regionDetail", "regionDetailTitle", "regionDetailList", "shareBtn", "requiredHint",
                    "consentMain", "consentDeclined",
                    "scoreChip", "quizScore", "scoresList", "scoresMeta",
                    "tokenScoreChip", "tokenScore"]
  static values  = {
    progressUrl: { type: String, default: "" },
    submitUrl: String,
    consentUrl: { type: String, default: "" },
    resultsUrl: { type: String, default: "" },
    regionsUrl: { type: String, default: "" },
    locale: { type: String, default: "" },
    shareUrl: { type: String, default: "" },
    showComparison: { type: Boolean, default: false },
    quiz: { type: Boolean, default: false },
    gradeUrl: { type: String, default: "" },
    quizStateUrl: { type: String, default: "" },
    scoresUrl: { type: String, default: "" },
    tokenisation: { type: Boolean, default: false },
    tokenTypes: { type: Array, default: [] },
    // Show each answer's own award as the respondent leaves the card, on top of
    // the running total (see _revealTokenEarn).
    tokenReveal: { type: Boolean, default: false },
    // Let a respondent return to a tokenised card they left unanswered and
    // still earn its points — what the server has always permitted.
    tokenBackNav: { type: Boolean, default: false },
    // Answer-branching: when on, next()/back() follow the answer-logic graph
    // instead of stepping linearly. Off ⇒ byte-identical linear behaviour.
    logic: { type: Boolean, default: false },
    // The resolved end screens (id/title/body/forward_url/forward_label). A
    // branch can finish on a specific one; _goToEnd records which via _endId.
    endScreens: { type: Array, default: [] },
    forwardLabel: { type: String, default: "" },
    current: { type: Number, default: 0 },
    // Form mode: same flow, but drop the game-like haptic buzz so it reads as a
    // plain questionnaire (motion/swipe are stripped via CSS + tap_stack).
    forms: { type: Boolean, default: false }
  }

  // Haptic feedback, suppressed in form mode.
  _buzz(pattern) {
    if (!this.formsValue) haptic(pattern)
  }

  _answers = {}
  _registered = false
  _regionsData = null

  // Answer-branching state: the visited-card stack (cardTarget indices, so
  // back() retraces the taken path, not idx-1), a hop budget that guarantees
  // termination on a malformed/looping graph, a cid→index lookup, and the end
  // screen a route sent us to (used once multiple end screens exist).
  _path = [0]
  _hops = 0
  _cidIndex = new Map()
  _endId = "default"

  // Regions map pan/zoom state — plain translate/scale, no external library.
  _mapScale = 1
  _mapX = 0
  _mapY = 0
  _mapPointers = new Map()
  _mapDragMoved = false
  _mapDragStart = { x: 0, y: 0 }
  _mapPinchStartDist = 0
  _mapPinchStartScale = 1

  // Quiz state: which card indices have been answered+revealed (so they can't
  // be redone), and the running score.
  _revealed = new Set()
  _quizScore = 0
  _quizMax = 0
  _scoresData = null

  // Tokenisation state: which card indices have already contributed to the
  // running total (so they can't be redone), and the running totals
  // themselves, keyed by token type id.
  _tokenLocked = new Set()
  _tokenTotals = {}

  connect() {
    this._sessionToken = this._ensureToken()
    this._nextLabel   = this.hasNextBtnTarget   ? this.nextBtnTarget.textContent   : ""
    this._finishLabel = this.hasFinishBtnTarget ? this.finishBtnTarget.textContent : ""
    this._path = [this.currentValue]
    this._hops = 0
    if (this.logicValue) {
      this._cidIndex = new Map(this.cardTargets.map((c, i) => [c.dataset.cardCid, i]))
    }
    this._update()
    if (this.quizValue) this._initQuiz()
    if (this.tokenisationValue) this._initTokens()
    if (this.hasRegionsMapViewportTarget) this._setupMapPanZoom()
  }

  // Consent card (the first card): agreeing advances into the deck; declining
  // swaps in a polite end-state and leaves the respondent on the gate. Both
  // record the event server-side for the audit trail — fire-and-forget, same
  // best-effort philosophy as _saveProgress(), so a network blip never blocks
  // the respondent's tap.
  agreeConsent() {
    this._buzz()
    this._recordConsent(true)
    this.next()
  }

  declineConsent() {
    this._recordConsent(false)
    if (this.hasConsentMainTarget) this.consentMainTarget.classList.add("hidden")
    if (this.hasConsentDeclinedTarget) this.consentDeclinedTarget.classList.remove("hidden")
  }

  _recordConsent(agreed) {
    if (!this.consentUrlValue) return
    fetch(this.consentUrlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session_token: this._sessionToken, agreed })
    }).catch(() => { /* best-effort — nothing to retry from here */ })
  }

  next() {
    // Scenario: the deck's Next means "turn the page" until the book's own
    // answer page is showing — otherwise one tap could skip the whole story
    // (and the choice) without the respondent ever seeing it.
    if (this._scenarioTurn(this.currentValue, 1)) return
    // Quiz: a graded card reveals right/wrong on the first Next, and only
    // advances on the second — so the player always sees how they did.
    if (this._needsReveal(this.currentValue)) {
      this._capture(this.currentValue)
      if (!this._requireGuard(this.currentValue)) return
      this._gradeCurrent()
      return
    }
    this._capture(this.currentValue)
    if (!this._requireGuard(this.currentValue)) return
    this._applyTokenEarn(this.currentValue)
    this._saveProgress()
    this._advance()
  }

  // Advance one step. Linear by default; follows the answer-logic graph when the
  // Verto has logic enabled (routing off ⇒ this is byte-identical to before).
  _advance() {
    if (this.logicValue) { this._advanceLogic(); return }
    if (this.currentValue < this.cardTargets.length - 1) {
      this._buzz()
      this.currentValue++
      this._update()
    }
  }

  back() {
    // Scenario: retrace pages before leaving the card, symmetric with next().
    if (this._scenarioTurn(this.currentValue, -1)) return
    this._capture(this.currentValue)
    this._saveProgress()
    if (this.logicValue) {
      // Retrace the taken path — a plain currentValue-- could land on a card
      // this respondent skipped by branching.
      if (this._path.length > 1) {
        this._path.pop()
        this.currentValue = this._path[this._path.length - 1]
        this._hops = Math.max(0, this._hops - 1)
        this._update()
      }
      return
    }
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  _payload() {
    let answers = this._answers
    // Under logic, only submit answers for cards actually on the taken path —
    // backing up and re-routing can leave a stale answer for a now-skipped
    // card, which the server's index-based quiz/token totals would else count.
    if (this.logicValue) {
      const keep = new Set(
        this._path.map(i => this.cardTargets[i]?.dataset.cardIndex).filter(k => k != null && k !== "")
      )
      answers = {}
      for (const [k, v] of Object.entries(this._answers)) if (keep.has(k)) answers[k] = v
    }
    return { session_token: this._sessionToken, answers, locale: this.localeValue }
  }

  async finish() {
    // Scenario: same interception as next() — a scenario can be the last card.
    if (this._scenarioTurn(this.currentValue, 1)) return
    // Quiz: if the last card is graded and unrevealed, reveal it first; the
    // player presses Finish again to actually submit.
    if (this._needsReveal(this.currentValue)) {
      this._capture(this.currentValue)
      if (!this._requireGuard(this.currentValue)) return
      await this._gradeCurrent()
      return
    }
    this._capture(this.currentValue)
    if (!this._requireGuard(this.currentValue)) return
    this._applyTokenEarn(this.currentValue)
    // Logic Vertos resolve the answer graph even on Finish — the terminal
    // card's chosen answer may still route onward, or to a specific end screen.
    if (this.logicValue) { await this._advanceLogic(); return }
    this._buzz([10, 30, 10]) // a little "done" buzz on completion
    await this._finalize()
  }

  // Submit the recorded answers and reveal the thank-you screen. Shared by the
  // linear Finish button and logic's _goToEnd, so both paths record identically.
  async _finalize() {
    // Owner preview runs without a submit endpoint — nothing is recorded,
    // just show the thank-you screen.
    if (!this.submitUrlValue) return this._showThankyou(false)
    let queued = false
    // No label swap (unlike _setGradingBusy) since that would need a new
    // translated string across all locales — the dimmed/not-allowed state
    // from [data-disabled="true"] already gives visible feedback and blocks
    // a second tap from firing a duplicate submit while this one is in flight.
    if (this.hasFinishBtnTarget) this.finishBtnTarget.dataset.disabled = "true"
    try {
      const res = await fetch(this.submitUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(this._payload())
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data = await res.clone().json().catch(() => null)
      queued = !!(data && data.queued)
      // Trust the server's final score over the running client tally.
      if (this.quizValue && data && typeof data.score === "number") {
        this._quizScore = data.score
        if (typeof data.max === "number") this._quizMax = data.max
      }
      // Trust the server's final token totals over the running client tally.
      if (this.tokenisationValue && data && data.token_totals && typeof data.token_totals === "object") {
        this._tokenTotals = { ...this._tokenTotals, ...data.token_totals }
      }
    } catch (_) {
      // No SW running and offline — answers are lost. Still show thank-you
      // so the player completes; flag as queued to set expectations.
      queued = !navigator.onLine
    } finally {
      if (this.hasFinishBtnTarget) this.finishBtnTarget.dataset.disabled = "false"
    }
    this._showThankyou(queued)
  }

  // ── Answer-branching: graph traversal ──────────────────────────────────────

  // Follow the answer-logic graph from the current card: hop to the resolved
  // next card, or finalise on a reached end screen. A hop budget guarantees
  // termination even on a malformed (looping) graph.
  async _advanceLogic() {
    const dest = this._resolveNext(this.currentValue)
    if (dest.index != null && dest.index >= 0 && dest.index < this.cardTargets.length) {
      if (this._hops >= this.cardTargets.length) { await this._goToEnd("default"); return }
      this._hops++
      this._buzz()
      this._path.push(dest.index)
      this.currentValue = dest.index
      this._update()
      return
    }
    await this._goToEnd(dest.end != null ? dest.end : "default")
  }

  // Reach an end screen: remember which one (used once multiple end screens
  // exist) and run the shared submit + thank-you finalise.
  async _goToEnd(id) {
    this._endId = id || "default"
    this._buzz([10, 30, 10])
    await this._finalize()
  }

  // Resolve the next step for the current card from its logic + captured answer.
  // Returns { index } to move to a card, or { end } to finish on an end screen.
  // Mirrors the server-side LogicGraph (app/lib/logic_graph.rb).
  _resolveNext(idx) {
    const card   = this.cardTargets[idx]
    const logic  = this._logicOf(card)
    const linear = { index: idx + 1 }
    const next   = this._nextOf(card) // unconditional flow pointer (any card type)
    if (!logic) {
      // Plain card: honour its `next` before falling to the linear next.
      return next ? (this._mapTarget(next) || linear) : linear
    }
    const value  = this._answers[card?.dataset.cardIndex]?.value
    const routes = Array.isArray(logic.routes) ? logic.routes : []
    let to = null
    for (const r of routes) {
      if (r && r.to && this._logicMatch(r.match, value)) { to = r.to; break }
    }
    if (!to && this._validTarget(logic.default)) to = logic.default
    if (!to && next) to = next // `next` is the otherwise when no route/default applies
    if (!to) return linear
    // A dangling cid target fails safe to the linear next card.
    return this._mapTarget(to) || linear
  }

  // A best-effort, answer-independent guess of whether the current card is the
  // last step (default/linear leads off the end), used only to toggle the
  // Next/Finish button label. A specific route to an end still finalises via
  // _advanceLogic regardless of the label.
  _staticNext(idx) {
    const card  = this.cardTargets[idx]
    const logic = this._logicOf(card)
    if (logic && this._validTarget(logic.default)) {
      const mapped = this._mapTarget(logic.default)
      if (mapped) return mapped
    }
    const next = this._nextOf(card)
    if (next) {
      const mapped = this._mapTarget(next)
      if (mapped) return mapped
    }
    const nxt = idx + 1
    return nxt < this.cardTargets.length ? { index: nxt } : { end: "default" }
  }

  _mapTarget(to) {
    if (!to || typeof to !== "object") return null
    if (to.end != null && to.end !== "") return { end: to.end }
    if (to.card != null && to.card !== "") {
      const ci = this._cidIndex.get(to.card)
      if (ci != null) return { index: ci }
    }
    return null
  }

  _validTarget(t) {
    return !!(t && typeof t === "object" &&
      ((t.card != null && t.card !== "") || (t.end != null && t.end !== "")))
  }

  // Mirrors LogicGraph.match?: "equals" for single-pick/scale answers,
  // "contains" for multi-pick arrays (fires when the answer includes the
  // value), "first" for prioritise (fires on the top-ranked value).
  _logicMatch(match, value) {
    if (!match || typeof match !== "object") return false
    switch (match.op) {
      case "equals": return this._norm(value) === this._norm(match.value)
      case "contains": {
        const list = Array.isArray(value) ? value : (value == null ? [] : [ value ])
        return list.some(v => this._norm(v) === this._norm(match.value))
      }
      case "first": return Array.isArray(value) && this._norm(value[0]) === this._norm(match.value)
      default: return false // unknown op fails safe to no-match (linear next)
    }
  }

  _norm(v) { return (v == null ? "" : String(v)).trim() }

  _logicOf(card) {
    const raw = card?.dataset.cardLogic
    if (!raw || raw === "null") return null
    try {
      const l = JSON.parse(raw)
      return (l && typeof l === "object") ? l : null
    } catch (_) { return null }
  }

  // The card's unconditional `next` flow pointer ({card}|{end}), or null.
  // Mirrors LogicGraph.card_next — honoured after answer routes/default.
  _nextOf(card) {
    const raw = card?.dataset.cardNext
    if (!raw || raw === "null") return null
    try {
      const n = JSON.parse(raw)
      return this._validTarget(n) ? n : null
    } catch (_) { return null }
  }

  // Share the public play link so respondents can pass the Verto on. Uses the
  // native share sheet where available (mobile), falling back to copying the
  // link to the clipboard with a brief ✓ on the button (desktop).
  async share() {
    const url = this.shareUrlValue || window.location.href
    if (navigator.share) {
      try {
        await navigator.share({ title: document.title, url })
      } catch (_) {
        // Sheet dismissed or failed — nothing more to do.
      }
      return
    }
    try {
      await navigator.clipboard.writeText(url)
      if (this.hasShareBtnTarget) {
        const btn = this.shareBtnTarget
        const original = btn.textContent
        btn.textContent = "✓"
        setTimeout(() => { btn.textContent = original }, 1800)
      }
    } catch (_) {
      window.prompt("", url)
    }
  }

  // A stable per-session token: persisted so a refresh reuses the same
  // response row rather than creating a duplicate.
  _ensureToken() {
    const newToken = () =>
      (typeof crypto !== "undefined" && crypto.randomUUID)
        ? crypto.randomUUID()
        : Math.random().toString(36).slice(2)
    const key = `verto_session_${this.submitUrlValue}`
    try {
      let t = sessionStorage.getItem(key)
      if (!t) { t = newToken(); sessionStorage.setItem(key, t) }
      return t
    } catch (_) {
      return newToken()
    }
  }

  // Register this session as a responder once it has ≥1 real answer, so people
  // who answer something then leave are still counted. Fire once on success.
  async _saveProgress() {
    if (this._registered || !this.progressUrlValue) return
    const hasAnswer = Object.values(this._answers).some(a => a && this._isAnswered(a.value))
    if (!hasAnswer) return
    try {
      const res = await fetch(this.progressUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(this._payload())
      })
      if (res.ok) this._registered = true
    } catch (_) { /* retry on the next navigation */ }
  }

  _isAnswered(value) {
    if (Array.isArray(value)) return value.length > 0
    return value !== null && value !== undefined && value !== ""
  }

  // Whether the card at `idx` has a usable answer (a value, or free-text Other).
  _isCardAnswered(idx) {
    const key = this.cardTargets[idx]?.dataset.cardIndex
    if (key === undefined || key === "") return true // non-answer cards never block
    const a = this._answers[key]
    if (!a) return false
    if (a.other && a.other.trim()) return true
    return this._isAnswered(a.value)
  }

  // Required gate: a card marked data-card-required must be answered before the
  // player advances past it. Returns true when it's safe to proceed.
  _requireGuard(idx) {
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardRequired !== "true" || this._isCardAnswered(idx)) {
      this._clearRequiredHint()
      return true
    }
    this._showRequiredHint(card)
    return false
  }

  // The scenario_controller instance for card `idx`, if it's a scenario card.
  _scenarioController(idx) {
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardType !== "scenario") return null
    const el = card.querySelector('[data-controller~="scenario"]')
    if (!el) return null
    return this.application.getControllerForElementAndIdentifier(el, "scenario")
  }

  // Ask card `idx`'s book to turn a page instead of the deck advancing.
  // Returns true if a page actually turned (book wasn't already at that
  // edge) — next()/back()/finish() fall through to normal navigation
  // otherwise, so a scenario at its answer page behaves like any other card.
  _scenarioTurn(idx, delta) {
    const ctrl = this._scenarioController(idx)
    if (!ctrl) return false
    return delta > 0 ? ctrl.next() : ctrl.back()
  }

  _showRequiredHint(card) {
    if (this.hasRequiredHintTarget) this.requiredHintTarget.classList.remove("hidden")
    if (card) {
      card.classList.remove("card-shake")
      void card.offsetWidth // reflow so the shake restarts on a repeated tap
      card.classList.add("card-shake")
    }
  }

  _clearRequiredHint() {
    if (this.hasRequiredHintTarget) this.requiredHintTarget.classList.add("hidden")
  }

  // Answers are keyed by the card's position in @survey.cards (data-card-index),
  // NOT its position among the card targets — the consent card carries no index
  // and is skipped, so prepending it never shifts the answer keys.
  _capture(idx) {
    const card = this.cardTargets[idx]
    if (!card) return
    const key = card.dataset.cardIndex
    if (key === undefined || key === "") return
    const type  = card.dataset.cardType
    const value = this._read(card, type)
    // "Other" is a standalone answer: if the respondent typed free text it
    // replaces any normal selection for this card.
    const other = card.querySelector("[data-other-input]")?.value.trim()
    this._answers[key] = other
      ? { type, value: null, other }
      : { type, value }
  }

  // The canonical (primary-language) label an option element answers as.
  _canonicalOf(el) {
    if (!el) return null
    const c = el.dataset.canonical
    if (c !== undefined && c !== "") return c
    return el.querySelector(".pick-text, .choice-label")?.textContent.trim() ?? null
  }

  _read(card, type) {
    switch (type) {
      // Choice answers store the CANONICAL (primary-language) option label, so
      // results aggregate across languages regardless of the displayed text.
      case "multiple_choice":
      case "yes_no":
      case "select_one_grid":
      case "scenario":
        return this._canonicalOf(
          card.querySelector('[data-picker-target="item"][data-selected="true"]')
        )

      case "select_many":
      case "select_many_grid":
        return Array.from(card.querySelectorAll('[data-picker-target="item"][data-selected="true"]'))
                    .map(el => this._canonicalOf(el))
                    .filter(v => v !== null)

      case "prioritise": {
        // The ordered canonical labels, top (highest priority) → bottom. Only
        // counts once the respondent has arranged the list.
        const list = card.querySelector(".prioritise-list")
        if (!list || list.dataset.prioritiseTouched !== "true") return null
        return Array.from(list.querySelectorAll(".prioritise-item"))
                    .map(el => this._canonicalOf(el))
                    .filter(v => v !== null)
      }

      case "range": {
        const dots   = Array.from(card.querySelectorAll(".s-dot"))
        const active = dots.findIndex(d => d.classList.contains("active"))
        return active >= 0 ? active : null
      }

      case "nps": {
        const el = card.querySelector(".nps-slider")
        if (el) {
          const v = el.dataset.npsValue
          return (v !== undefined && v !== "") ? Number(v) : null
        }
        // Feature flag off: the card is rendered as a plain range slider.
        const dots   = Array.from(card.querySelectorAll(".s-dot"))
        const active = dots.findIndex(d => d.classList.contains("active"))
        return active >= 0 ? active : null
      }

      case "rating": {
        const count = Array.from(card.querySelectorAll(".rating-star.active")).length
        return count > 0 ? count : null
      }

      case "tap_card": {
        const wrap = card.querySelector(".rotate-wrap")
        try { return JSON.parse(wrap?.dataset.swipeResults || "null") } catch { return null }
      }

      case "open_ended": {
        // Location demographic: a hidden input carries the resolved
        // "CC|Label" the location-search widget picked (see
        // location_search_controller.js) — this is the app's one universal
        // source of region data (see PlayerController#sync_region_from_answers!).
        const loc = card.querySelector(".location-search-value")
        if (loc) return loc.value || null

        // Month+year demographic: two plain numeric fields, not a native
        // <input type="month"> (see _card_component.html.erb) — combine them
        // into the same "YYYY-MM" shape a native month input would have given.
        const month = card.querySelector(".freeform-month")
        if (month) {
          const year = card.querySelector(".freeform-year")
          const m = month.value.trim(), y = year?.value.trim()
          return (m && y && y.length === 4) ? `${y}-${m.padStart(2, "0")}` : null
        }
        const el = card.querySelector("textarea, input[type='date']")
        return el?.value?.trim() || null
      }

      default:
        return null
    }
  }

  _showThankyou(queued = false) {
    this.cardTargets.forEach(c => c.classList.remove("active"))
    this._applyEndScreen(this._endId)
    this.thankyouTarget.classList.add("active")
    this.backBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.add("hidden")
    this.finishBtnTarget.classList.add("hidden")
    this.progressTarget.textContent = ""
    if (queued && this.hasThankyouMainTarget && !this.thankyouMainTarget.querySelector(".preview-queued-pill")) {
      const pill = document.createElement("div")
      pill.className = "preview-queued-pill"
      pill.textContent = t("player.queued")
      this.thankyouMainTarget.appendChild(pill)
    }
    if (this.quizValue) this._renderQuizScore()
    if (this.tokenisationValue) this._renderTokenScore()
  }

  // Swap the thank-you screen's title / message / forward CTA to the end screen
  // a branch routed to (default when unrouted or the id is unknown — fail-safe).
  _applyEndScreen(id) {
    const screens = this.endScreensValue || []
    if (!screens.length) return
    const s = screens.find(x => x.id === id) ||
              screens.find(x => x.id === "default") || screens[0]
    if (!s) return
    if (this.hasThankyouTitleTarget && s.title) this.thankyouTitleTarget.textContent = s.title
    if (this.hasThankyouSubTarget && s.body != null) {
      this.thankyouSubTarget.replaceChildren()
      String(s.body).split("\n").forEach((line, i) => {
        if (i) this.thankyouSubTarget.appendChild(document.createElement("br"))
        this.thankyouSubTarget.appendChild(document.createTextNode(line))
      })
    }
    if (this.hasForwardBtnTarget) {
      if (s.forward_url) {
        this.forwardBtnTarget.href = s.forward_url
        this.forwardBtnTarget.textContent = `${s.forward_label || this.forwardLabelValue || "Visit website"} →`
        this.forwardBtnTarget.classList.remove("hidden")
      } else {
        this.forwardBtnTarget.classList.add("hidden")
      }
    }
  }

  // One button, one panel: the quiz score section and the general answer-
  // comparison section each load independently (whichever the creator has
  // turned on) so one being slow/unavailable never blocks the other.
  async showCompare() {
    const wantScores  = this.hasScoresSectionTarget
    const wantCompare = this.showComparisonValue && this.resultsUrlValue && this.hasComparisonSectionTarget
    if (!wantScores && !wantCompare || !this.hasComparePanelTarget) return

    this.thankyouMainTarget.classList.add("hidden")
    this.comparePanelTarget.classList.remove("hidden")
    if (this.hasCompareBtnTarget) this.compareBtnTarget.disabled = true

    const tasks = []
    if (wantScores) tasks.push(this._loadScores())
    if (wantCompare) tasks.push(this._loadComparison())
    await Promise.all(tasks)

    if (this.hasCompareBtnTarget) this.compareBtnTarget.disabled = false
  }

  hideCompare() {
    if (this.hasComparePanelTarget) this.comparePanelTarget.classList.add("hidden")
    if (this.hasThankyouMainTarget) this.thankyouMainTarget.classList.remove("hidden")
  }

  async _loadComparison() {
    if (this.hasComparisonMetaTarget) this.comparisonMetaTarget.textContent = t("player.compare_loading")
    try {
      const res  = await fetch(this.resultsUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed to load results")
      this._renderComparison(data)
    } catch (e) {
      if (this.hasComparisonMetaTarget) this.comparisonMetaTarget.textContent = t("player.compare_error")
    }
  }

  // ── Regions map: where answers came from, per-region comparison ──

  async showRegions() {
    if (!this.regionsUrlValue || !this.hasRegionsPanelTarget) return
    this.thankyouMainTarget.classList.add("hidden")
    if (this.hasComparePanelTarget) this.comparePanelTarget.classList.add("hidden")
    this.regionsPanelTarget.classList.remove("hidden")
    this._resetMapView()
    if (this._regionsData) return
    this.regionsMetaTarget.textContent = t("player.compare_loading")
    try {
      const res  = await fetch(this.regionsUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed to load regions")
      this._regionsData = data
      this._renderRegions(data)
    } catch (_) {
      this.regionsMetaTarget.textContent = t("player.compare_error")
    }
  }

  // Back button: detail view returns to the map, the map closes the panel.
  hideRegions() {
    if (this.hasRegionDetailTarget && !this.regionDetailTarget.classList.contains("hidden")) {
      this.regionDetailTarget.classList.add("hidden")
      this.regionsMainTarget.classList.remove("hidden")
      return
    }
    this.regionsPanelTarget.classList.add("hidden")
    this.thankyouMainTarget.classList.remove("hidden")
  }

  _renderRegions(data) {
    const regions = data.regions || []
    this.regionsMetaTarget.textContent = t("player.region_meta", { count: data.total_tagged || 0 })

    // Choropleth: tint each country by its share of region-tagged responses.
    // Some countries are <g> groups — inline fill must land on the paths to
    // beat the stylesheet's base fill.
    const byCountry = {}
    regions.forEach(r => { byCountry[r.country] = (byCountry[r.country] || 0) + r.responders })
    const max = Math.max(1, ...Object.values(byCountry))
    const svg = this.regionsPanelTarget.querySelector(".world-map")
    if (svg) Object.entries(byCountry).forEach(([cc, n]) => {
      const el = svg.querySelector(`#${cc.toLowerCase()}`)
      if (!el) return
      const alpha = 0.18 + 0.72 * (n / max)
      const paths = el.tagName.toLowerCase() === "g" ? el.querySelectorAll("path") : [el]
      paths.forEach(p => { p.style.fill = `rgba(1,234,203,${alpha.toFixed(2)})` })
      const tip = document.createElementNS("http://www.w3.org/2000/svg", "title")
      tip.textContent = `${regions.find(r => r.country === cc)?.country_name || cc}: ${n}`
      el.appendChild(tip)
      el.style.cursor = "pointer"
      el.addEventListener("click", () => this._highlightCountry(cc))
    })

    const list = this.regionsListTarget
    list.innerHTML = ""
    if (regions.length === 0) {
      const empty = document.createElement("div")
      empty.style.cssText = "font-family:'ABeeZee',sans-serif;font-size:12px;color:rgba(255,255,255,0.5);text-align:center;padding:10px;"
      empty.textContent = t("player.region_empty")
      list.appendChild(empty)
      return
    }
    regions.forEach(region => {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "region-row"
      row.dataset.country = region.country
      const name = document.createElement("span")
      name.style.cssText = "flex:1;text-align:start;font-family:'ABeeZee',sans-serif;font-size:13px;color:#fff;"
      name.textContent = region.label ? `${region.country_name} · ${region.label}` : region.country_name
      const count = document.createElement("span")
      count.style.cssText = "font-family:'Alata',sans-serif;font-size:12px;color:#01EACB;"
      count.textContent = t("player.region_answered", { count: region.responders })
      const arrow = document.createElement("span")
      arrow.style.cssText = "font-family:'ABeeZee',sans-serif;font-size:12px;color:rgba(255,255,255,0.45);"
      arrow.textContent = t("player.region_compare")
      row.append(name, count, arrow)
      row.addEventListener("click", () => this._showRegionDetail(region))
      list.appendChild(row)
    })
  }

  _highlightCountry(cc) {
    this.regionsListTarget.querySelectorAll(".region-row").forEach(row => {
      row.classList.toggle("active-country", row.dataset.country === cc)
    })
    const first = this.regionsListTarget.querySelector(`.region-row[data-country="${cc}"]`)
    if (first) first.scrollIntoView({ behavior: "smooth", block: "nearest" })
  }

  // Region vs you: reuses the comparison row renderer, so each question shows
  // the region's distribution with this respondent's own answer highlighted.
  _showRegionDetail(region) {
    this.regionsMainTarget.classList.add("hidden")
    this.regionDetailTarget.classList.remove("hidden")
    const name = region.label ? `${region.country_name} · ${region.label}` : region.country_name
    this.regionDetailTitleTarget.textContent =
      `${name} — ${t("player.region_answered", { count: region.responders })}`
    const list = this.regionDetailListTarget
    list.innerHTML = ""
    ;(region.results || []).forEach(row => {
      if (row.type === "welcome_card" || row.type === "token_checkpoint") return
      const mine = this._answers[String(row.index)]?.value
      list.appendChild(this._buildRow(row, mine))
    })
  }

  // ── Regions map pan/zoom: plain translate+scale on the stage div, driven
  // by Pointer Events (mouse drag, touch drag, two-finger pinch) and wheel.
  // A "click" that lands right after a drag/pinch is swallowed at the
  // capture phase so panning never mis-fires a country selection.

  _setupMapPanZoom() {
    const vp = this.regionsMapViewportTarget
    vp.addEventListener("wheel", this._onMapWheel.bind(this), { passive: false })
    vp.addEventListener("pointerdown", this._onMapPointerDown.bind(this))
    vp.addEventListener("pointermove", this._onMapPointerMove.bind(this))
    vp.addEventListener("pointerup", this._onMapPointerUp.bind(this))
    vp.addEventListener("pointercancel", this._onMapPointerUp.bind(this))
    vp.addEventListener("click", this._onMapClickCapture.bind(this), true)
  }

  _resetMapView() {
    this._mapScale = 1
    this._mapX = 0
    this._mapY = 0
    this._applyMapTransform()
  }

  resetMapView() {
    if (!this.hasRegionsMapStageTarget) return
    this.regionsMapStageTarget.classList.add("is-animating")
    this._resetMapView()
    setTimeout(() => this.regionsMapStageTarget.classList.remove("is-animating"), 260)
  }

  zoomInMap()  { this._zoomAroundViewportCenter(1.5) }
  zoomOutMap() { this._zoomAroundViewportCenter(1 / 1.5) }

  _zoomAroundViewportCenter(factor) {
    if (!this.hasRegionsMapViewportTarget) return
    const rect = this.regionsMapViewportTarget.getBoundingClientRect()
    this.regionsMapStageTarget.classList.add("is-animating")
    this._zoomAt(rect.width / 2, rect.height / 2, factor)
    setTimeout(() => this.regionsMapStageTarget.classList.remove("is-animating"), 260)
  }

  // Keeps the point under (cx, cy) — in viewport-local pixels — visually
  // fixed while the scale changes, the standard "zoom to point" transform.
  _zoomAt(cx, cy, factor) {
    const newScale = Math.min(MAP_MAX_SCALE, Math.max(MAP_MIN_SCALE, this._mapScale * factor))
    if (newScale === this._mapScale) return
    this._mapX = cx - (newScale / this._mapScale) * (cx - this._mapX)
    this._mapY = cy - (newScale / this._mapScale) * (cy - this._mapY)
    this._mapScale = newScale
    this._applyMapTransform()
  }

  _applyMapTransform() {
    if (!this.hasRegionsMapStageTarget) return
    this.regionsMapStageTarget.style.transform =
      `translate(${this._mapX}px, ${this._mapY}px) scale(${this._mapScale})`
  }

  _onMapWheel(e) {
    e.preventDefault()
    const rect = this.regionsMapViewportTarget.getBoundingClientRect()
    const factor = Math.pow(1.0015, -e.deltaY)
    this._zoomAt(e.clientX - rect.left, e.clientY - rect.top, factor)
  }

  _onMapPointerDown(e) {
    // Reset before the zoom-btn early-return below, so a stale "true" left
    // over from a pan that ended over the map can never survive into the
    // next tap and get misread by _onMapClickCapture as another drag.
    this._mapDragMoved = false
    // Let zoom-control buttons handle their own clicks — capturing the
    // pointer here would retarget their mouseup/click to the viewport instead.
    if (e.target.closest(".regions-zoom-btn")) return
    this.regionsMapViewportTarget.setPointerCapture(e.pointerId)
    this._mapPointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
    this._mapDragStart = { x: e.clientX, y: e.clientY }
    if (this._mapPointers.size === 2) {
      const [a, b] = [...this._mapPointers.values()]
      this._mapPinchStartDist = Math.hypot(a.x - b.x, a.y - b.y) || 1
      this._mapPinchStartScale = this._mapScale
    }
    this.regionsMapViewportTarget.classList.add("is-dragging")
  }

  _onMapPointerMove(e) {
    if (!this._mapPointers.has(e.pointerId)) return
    const prev = this._mapPointers.get(e.pointerId)
    this._mapPointers.set(e.pointerId, { x: e.clientX, y: e.clientY })

    if (this._mapPointers.size === 2) {
      const [a, b] = [...this._mapPointers.values()]
      const rect = this.regionsMapViewportTarget.getBoundingClientRect()
      const dist = Math.hypot(a.x - b.x, a.y - b.y) || 1
      const midX = (a.x + b.x) / 2 - rect.left
      const midY = (a.y + b.y) / 2 - rect.top
      const target = Math.min(MAP_MAX_SCALE, Math.max(MAP_MIN_SCALE,
        this._mapPinchStartScale * (dist / this._mapPinchStartDist)))
      this._mapX = midX - (target / this._mapScale) * (midX - this._mapX)
      this._mapY = midY - (target / this._mapScale) * (midY - this._mapY)
      this._mapScale = target
      this._applyMapTransform()
      this._mapDragMoved = true
      return
    }

    this._mapX += e.clientX - prev.x
    this._mapY += e.clientY - prev.y
    if (Math.abs(e.clientX - this._mapDragStart.x) > 4 || Math.abs(e.clientY - this._mapDragStart.y) > 4) {
      this._mapDragMoved = true
    }
    this._applyMapTransform()
  }

  _onMapPointerUp(e) {
    this._mapPointers.delete(e.pointerId)
    if (this._mapPointers.size === 0) {
      this.regionsMapViewportTarget.classList.remove("is-dragging")
    } else {
      // Dropped from a pinch back to a single finger — resync the pan
      // baseline so the remaining pointer doesn't jump on its next move.
      const [remaining] = this._mapPointers.values()
      this._mapDragStart = { x: remaining.x, y: remaining.y }
    }
  }

  // Suppresses the ghost "click" a browser fires on pointerup after a
  // drag/pinch, so panning the map never mis-selects the country underneath.
  _onMapClickCapture(e) {
    if (this._mapDragMoved) {
      e.stopPropagation()
      e.preventDefault()
      this._mapDragMoved = false
    }
  }

  _renderComparison(data) {
    const total = data.total_responses || 0
    if (this.hasComparisonMetaTarget) {
      this.comparisonMetaTarget.textContent =
        `Based on ${total} response${total === 1 ? "" : "s"} (including yours)`
    }
    const list = this.comparisonListTarget
    list.innerHTML = ""
    ;(data.results || []).forEach(row => {
      if (row.type === "welcome_card" || row.type === "token_checkpoint") return
      // Tokenisation: synthetic rows appended by PlayerController#results
      // (folding "compare your tokens" into this same panel) aren't keyed to
      // a card index — "mine" is this session's own final total instead.
      const mine = row.type === "token_total"
        ? (this._tokenTotals[row.token_id] || 0)
        : this._answers[String(row.index)]?.value
      list.appendChild(this._buildRow(row, mine))
    })
  }

  _buildRow(row, mine) {
    const wrap = document.createElement("div")
    wrap.style.cssText = "background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.08);border-radius:14px;padding:14px 16px;"

    const prompt = document.createElement("div")
    prompt.style.cssText = "font-family:'ABeeZee',sans-serif;font-size:13px;color:#fff;line-height:1.45;margin-bottom:10px;"
    prompt.textContent = row.prompt || `Question ${row.index + 1}`
    wrap.appendChild(prompt)

    const yourPill = document.createElement("div")
    yourPill.style.cssText = "display:inline-block;padding:4px 10px;border-radius:100px;background:var(--brand-primary-soft,rgba(1,234,203,0.15));color:var(--brand-primary,#01EACB);font-family:'ABeeZee',sans-serif;font-size:11px;margin-bottom:10px;"
    yourPill.textContent = `Your answer: ${this._formatMine(mine, row)}`
    wrap.appendChild(yourPill)

    const body = this._buildDistribution(row, mine)
    if (body) wrap.appendChild(body)

    return wrap
  }

  _formatMine(mine, row) {
    if (mine === null || mine === undefined || mine === "") return "—"
    if (row.type === "prioritise" && Array.isArray(mine)) return mine.length ? mine.join(" › ") : "—"
    if (Array.isArray(mine)) return mine.length ? mine.join(", ") : "—"
    if ((row.type === "range" || row.type === "nps") && Array.isArray(row.options)) {
      return row.options[mine] || `Step ${Number(mine) + 1}`
    }
    if (row.type === "rating") return `${mine} ★`
    if (typeof mine === "object") {
      return Object.entries(mine).map(([k, v]) => `${k}: ${v}`).join(", ")
    }
    return String(mine)
  }

  _buildDistribution(row, mine) {
    const container = document.createElement("div")
    container.style.cssText = "display:flex;flex-direction:column;gap:14px;"

    const counts = row.counts || {}
    let entries = []

    if ((row.type === "range" || row.type === "nps") && Array.isArray(row.options)) {
      entries = row.options.map((label, i) => [label, counts[i] || counts[String(i)] || 0, i])
    } else if (row.type === "rating") {
      const max = Math.max(5, ...Object.keys(counts).map(k => parseInt(k) || 0))
      for (let i = 1; i <= max; i++) entries.push([`${i} ★`, counts[i] || counts[String(i)] || 0, i])
    } else if (row.type === "open_ended") {
      const note = document.createElement("div")
      note.style.cssText = "font-family:'ABeeZee',sans-serif;font-size:11px;color:rgba(255,255,255,0.4);font-style:italic;"
      note.textContent = `${row.total || 0} open-ended response${row.total === 1 ? "" : "s"} total`
      container.appendChild(note)
      return container
    } else if (row.type === "token_total") {
      // Tokenisation compare row: counts is a histogram keyed by exact total
      // amount (mirrors the quiz score distribution) — sort ascending and
      // highlight this session's own bucket.
      const amounts = Object.keys(counts).map(Number).sort((a, b) => a - b)
      const grand = amounts.reduce((s, a) => s + (counts[a] || counts[String(a)] || 0), 0) || 1
      amounts.forEach(amt => {
        const count = counts[amt] || counts[String(amt)] || 0
        const pct = Math.round((count / grand) * 100)
        container.appendChild(this._buildBar(String(amt), count, pct, Number(mine) === amt))
      })
      return container
    } else if (row.type === "prioritise") {
      // counts[label] = sum of ranks across responders; lower mean = higher
      // priority. Show the aggregate order with each option's average position.
      const total = row.total || 1
      const ranked = Object.entries(counts)
        .map(([label, sumRank]) => ({ label, mean: sumRank / total }))
        .sort((a, b) => a.mean - b.mean)
      const n = ranked.length || 1
      ranked.forEach(({ label, mean }, i) => {
        const pct = Math.round(Math.max(0, Math.min(1, (n - mean + 1) / n)) * 100)
        container.appendChild(this._buildBar(`${i + 1}. ${label}`, `avg ${mean.toFixed(1)}`, pct, false))
      })
      return container
    } else if (row.type === "tap_card") {
      Object.entries(counts).forEach(([label, yn]) => {
        const yes = (yn && yn.yes) || 0, no = (yn && yn.no) || 0, unsure = (yn && yn.unsure) || 0
        const sum = yes + no + unsure || 1
        entries.push([`${label} — Yes`,    yes,    `${label}:yes`,    sum])
        entries.push([`${label} — Unsure`, unsure, `${label}:unsure`, sum])
        entries.push([`${label} — No`,     no,     `${label}:no`,     sum])
      })
    } else {
      // Unordered options (multiple choice, yes/no, …) read best as a ranked
      // chart — most popular first.
      entries = Object.entries(counts)
        .map(([label, n]) => [label, n, label])
        .sort((a, b) => b[1] - a[1])
    }

    if (entries.length === 0) return null

    const grand = entries.reduce((s, e) => s + (e[3] || e[1]), 0) || 1
    entries.forEach(([label, count, key, denom]) => {
      const pct = Math.round((count / (denom || grand)) * 100)
      const isMine = this._isMineMatch(mine, key, row)
      container.appendChild(this._buildBar(label, count, pct, isMine))
    })
    return container
  }

  _isMineMatch(mine, key, row) {
    if (mine === null || mine === undefined) return false
    if (Array.isArray(mine)) return mine.map(String).includes(String(key))
    if (row.type === "range" || row.type === "nps") return Number(mine) === Number(key)
    if (row.type === "rating") return Number(mine) === Number(key)
    if (row.type === "tap_card" && typeof mine === "object" && typeof key === "string") {
      const [label, choice] = key.split(":")
      return mine[label] === choice
    }
    return String(mine) === String(key)
  }

  _buildBar(label, count, pct, isMine) {
    const row = document.createElement("div")
    row.style.cssText = "display:flex;flex-direction:column;gap:5px;"

    // Header: full label (the respondent's choice is dotted + brand-coloured),
    // a prominent percentage, and the raw count.
    const head = document.createElement("div")
    head.style.cssText = "display:flex;align-items:baseline;gap:8px;"

    const lbl = document.createElement("span")
    lbl.style.cssText = `flex:1;min-width:0;font-family:'ABeeZee',sans-serif;font-size:12px;line-height:1.35;color:${isMine ? "var(--brand-primary,#01EACB)" : "rgba(255,255,255,0.82)"};`
    lbl.textContent = (isMine ? "● " : "") + label
    head.appendChild(lbl)

    const pctEl = document.createElement("span")
    pctEl.style.cssText = "flex-shrink:0;font-family:'Alata',sans-serif;font-size:14px;color:#fff;"
    pctEl.textContent = `${pct}%`
    head.appendChild(pctEl)

    const countEl = document.createElement("span")
    countEl.style.cssText = "flex-shrink:0;min-width:22px;text-align:right;font-family:'ABeeZee',sans-serif;font-size:11px;color:rgba(255,255,255,0.4);"
    countEl.textContent = count
    head.appendChild(countEl)
    row.appendChild(head)

    // Thicker track with a fill that animates up from zero on render.
    const track = document.createElement("div")
    track.style.cssText = "height:10px;border-radius:5px;background:rgba(255,255,255,0.07);overflow:hidden;"
    const fill = document.createElement("div")
    fill.style.cssText = `height:100%;border-radius:5px;width:0;transition:width 0.7s cubic-bezier(0.16,1,0.3,1);background:${isMine ? "var(--brand-primary,#01EACB)" : "rgba(255,255,255,0.3)"};`
    track.appendChild(fill)
    row.appendChild(track)
    requestAnimationFrame(() => { fill.style.width = `${pct}%` })

    return row
  }

  _update() {
    this._clearRequiredHint()
    const cards = this.cardTargets
    const idx   = this.currentValue
    cards.forEach((c, i) => c.classList.toggle("active", i === idx))

    // Two gate shapes: "consent_card" is the survey-level pseudo-card pinned
    // first, "consent_gate" is a real multi-page card the creator placed in the
    // deck. Both drive themselves, so both suppress the deck nav; only a gate
    // sitting FIRST is held out of the progress count, the same way a mid-deck
    // welcome card or checkpoint is counted where it stands.
    const hasConsent = CONSENT_TYPES.includes(cards[0]?.dataset.cardType)
    const onConsent  = CONSENT_TYPES.includes(cards[idx]?.dataset.cardType)

    if (onConsent) {
      // The consent gate drives itself (Agree / decline) — hide the deck nav.
      // A multi-page gate turns its pages with the book's own chevrons, so
      // nothing here needs to reach them.
      this.progressTarget.textContent = ""
      this.element.style.setProperty("--player-progress", "0%")
      this.backBtnTarget.classList.add("invisible")
      this.nextBtnTarget.classList.add("hidden")
      this.finishBtnTarget.classList.add("hidden")
      return
    }

    // Keep the consent card out of the progress the respondent sees.
    const offset = hasConsent ? 1 : 0
    const total  = cards.length - offset
    // With logic the path is variable and its length unknown up front, so show
    // honest, monotonic path progress against the deck size as a loose upper
    // bound. Linear mode keeps its exact "n of N". The path stack already
    // includes the consent card when present, so it shares the same offset.
    const n = this.logicValue
      ? Math.min(Math.max(this._path.length - offset, 1), total)
      : idx + 1 - offset
    this.progressTarget.textContent = t("player.progress", { n, total })
    this.element.style.setProperty("--player-progress", `${Math.min(100, Math.round((n / total) * 100))}%`)
    this.backBtnTarget.classList.remove("hidden")
    // Don't allow stepping back onto the consent gate once agreed (or off the
    // start of the visited path under logic).
    this.backBtnTarget.classList.toggle("invisible", this.logicValue ? this._path.length <= 1 : idx === offset)
    // Under logic, "last" depends on the graph, not the array position.
    const isLast = this.logicValue ? (this._staticNext(idx).end != null) : (idx === cards.length - 1)
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
    if (this.quizValue) this._labelQuizNav()
    if (this.tokenisationValue) this._maybeRenderCheckpoint(idx)
  }

  // ── Quiz: per-card grading, reveal, lock, running score ──────────────────

  async _initQuiz() {
    this._quizMax = this.cardTargets.filter(c => c.dataset.cardGraded === "true").length
    this._renderScoreChip()

    // Refresh-proof no-redo: re-lock and re-reveal cards this session already
    // committed, server-side (owner preview has no endpoint and starts fresh).
    if (!this.quizStateUrlValue) return
    try {
      const url = `${this.quizStateUrlValue}?session_token=${encodeURIComponent(this._sessionToken)}`
      const res  = await fetch(url, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data || !data.ok || !data.quiz) return
      if (typeof data.max === "number") this._quizMax = data.max
      Object.entries(data.answered || {}).forEach(([key, info]) => {
        const card = this.cardTargets.find(c => c.dataset.cardIndex === key)
        if (!card) return
        this._answers[key] = { type: card.dataset.cardType, value: info.value }
        this._applyValue(card, card.dataset.cardType, info.value)
        this._revealCard(card, { correct: info.correct, correctAnswer: info.correct_answer,
                                 explanation: info.explanation, mine: info.value })
        this._revealed.add(this.cardTargets.indexOf(card))
      })
      if (typeof data.score === "number") this._quizScore = data.score
      this._renderScoreChip()
      this._update()
    } catch (_) { /* a fresh start is fine if state can't load */ }
  }

  // A card that still needs its quiz reveal before the player can move on.
  _needsReveal(idx) {
    const card = this.cardTargets[idx]
    return this.quizValue && card?.dataset.cardGraded === "true" && !this._revealed.has(idx)
  }

  async _gradeCurrent() {
    const idx  = this.currentValue
    const card = this.cardTargets[idx]
    const key  = card.dataset.cardIndex
    this._revealed.add(idx) // lock now so a double-tap can't re-submit
    card.classList.add("quiz-locking")
    this._setGradingBusy(true)

    const result = this.gradeUrlValue
      ? await this._gradeRemote(key)         // live: server is authoritative
      : this._gradeLocal(card)               // owner preview: embedded answers
    card.classList.remove("quiz-locking")
    this._setGradingBusy(false)
    if (!result) { this._revealed.delete(idx); return } // couldn't grade — allow a retry

    if (typeof result.score === "number") this._quizScore = result.score
    else if (result.correct) this._quizScore++
    if (typeof result.max === "number") this._quizMax = result.max

    this._revealCard(card, result)
    this._renderScoreChip()
    this._update()
    this._buzz(result.correct ? [12, 24, 12] : 30)
  }

  // Disables Next/Submit and swaps its label while the server checks the
  // answer — a free-text quiz answer can take a couple of seconds now that a
  // close-but-not-exact wording gets an AI judgment call (see
  // QuizAnswerGrader), not just an instant exact-match. Guards against a
  // confused double-tap mid-request.
  _setGradingBusy(busy) {
    const label = busy ? t("player.quiz_grading") : t("player.quiz_check")
    ;[ this.hasNextBtnTarget && this.nextBtnTarget, this.hasFinishBtnTarget && this.finishBtnTarget ]
      .filter(Boolean)
      .forEach(btn => { btn.textContent = label; btn.dataset.disabled = busy ? "true" : "false" })
  }

  async _gradeRemote(key) {
    try {
      const res = await fetch(this.gradeUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...this._payload(), card_index: Number(key) })
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data = await res.json()
      if (!data.ok || !data.graded) return null
      return { correct: data.correct, correctAnswer: data.correct_answer,
               explanation: data.explanation, score: data.score, max: data.max,
               mine: this._answers[key]?.value }
    } catch (_) { return null }
  }

  _gradeLocal(card) {
    let correct
    try { correct = JSON.parse(card.dataset.cardCorrect || "null") } catch (_) { correct = null }
    if (correct === null || correct === undefined || correct === "" ||
        (Array.isArray(correct) && correct.length === 0)) return null
    const value = this._answers[card.dataset.cardIndex]?.value
    return { correct: this._matchCorrect(card.dataset.cardType, value, correct),
             correctAnswer: correct, explanation: card.dataset.cardExplanation || "", mine: value }
  }

  // Client mirror of QuizGrading#correct? — used ONLY for owner preview, where
  // the correct answers are embedded on the page. Live grading is server-side.
  _matchCorrect(type, value, correct) {
    const norm  = v => String(v ?? "").trim()
    const normT = v => norm(v).toLowerCase().replace(/\s+/g, " ")
    switch (type) {
      case "multiple_choice": case "yes_no": case "select_one_grid": case "scenario":
        return norm(value) === norm(correct)
      case "select_many": case "select_many_grid": {
        const a = new Set((Array.isArray(value) ? value : []).map(norm).filter(Boolean))
        const b = new Set((Array.isArray(correct) ? correct : []).map(norm).filter(Boolean))
        return a.size === b.size && [ ...a ].every(x => b.has(x))
      }
      case "tap_card": {
        if (typeof value !== "object" || !value || typeof correct !== "object" || !correct) return false
        const keys = Object.keys(correct).filter(k => correct[k] === "yes" || correct[k] === "no")
        return keys.length > 0 && keys.every(k => value[k] === correct[k])
      }
      case "range": case "nps": case "rating":
        if (value === null || value === undefined || value === "") return false
        return Number(value) === Number(correct)
      case "open_ended": {
        if (!norm(value)) return false
        return (Array.isArray(correct) ? correct : [ correct ]).map(normT).filter(Boolean).includes(normT(value))
      }
      default: return false
    }
  }

  _revealCard(card, { correct, correctAnswer, explanation, mine }) {
    card.classList.add("quiz-locked", correct ? "quiz-correct" : "quiz-wrong")
    this._lockInputs(card)
    this._tintOptions(card, correctAnswer, mine)

    const host = card.querySelector(".split-right") || card
    let banner = host.querySelector(".quiz-reveal")
    if (!banner) {
      banner = document.createElement("div")
      banner.className = "quiz-reveal"
      host.appendChild(banner)
    }
    banner.classList.toggle("is-correct", !!correct)
    banner.classList.toggle("is-wrong", !correct)
    const parts = [
      `<div class="quiz-reveal-head">${correct ? "✓" : "✗"} ${this._esc(correct ? t("player.quiz_correct") : t("player.quiz_wrong"))}</div>`
    ]
    if (!correct) {
      parts.push(`<div class="quiz-reveal-answer">${this._esc(t("player.quiz_answer"))} ${this._esc(this._formatCorrect(card.dataset.cardType, correctAnswer))}</div>`)
    }
    if (explanation) parts.push(`<div class="quiz-reveal-expl">${this._esc(explanation)}</div>`)
    banner.innerHTML = parts.join("")
  }

  // Tint the correct option(s) green and the player's wrong pick(s) red — for
  // the list/grid/yes-no types whose options carry a canonical label.
  _tintOptions(card, correctAnswer, mine) {
    const items = Array.from(card.querySelectorAll('[data-picker-target="item"]'))
    if (!items.length) return
    const toSet = v => new Set((Array.isArray(v) ? v : [ v ]).map(x => String(x ?? "").trim()).filter(Boolean))
    const right = toSet(correctAnswer), picked = toSet(mine)
    items.forEach(el => {
      const canon = (el.dataset.canonical || "").trim()
      if (right.has(canon)) el.classList.add("opt-correct")
      else if (picked.has(canon)) el.classList.add("opt-wrong")
    })
  }

  // Restore the player's recorded selection when rehydrating a locked card on
  // reload (choice/grid/open/rating); other widgets rely on the reveal banner.
  _applyValue(card, type, value) {
    if (value === null || value === undefined) return
    if ([ "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid", "scenario" ].includes(type)) {
      const set = new Set((Array.isArray(value) ? value : [ value ]).map(v => String(v ?? "").trim()))
      card.querySelectorAll('[data-picker-target="item"]').forEach(el => {
        if (set.has((el.dataset.canonical || "").trim())) el.dataset.selected = "true"
      })
    } else if (type === "open_ended") {
      const loc = card.querySelector(".location-search-value")
      if (loc) {
        loc.value = value
        const sep = String(value).indexOf("|")
        const label = sep >= 0 ? String(value).slice(sep + 1) : ""
        if (label) {
          const selected = card.querySelector(".location-search-selected")
          const selectedText = card.querySelector('[data-location-search-target="selectedText"]')
          const input = card.querySelector('[data-location-search-target="input"]')
          if (selected) selected.hidden = false
          if (selectedText) selectedText.textContent = label
          if (input) input.hidden = true
        }
        return
      }
      const month = card.querySelector(".freeform-month")
      if (month) {
        const m = /^(\d{4})-(\d{2})$/.exec(String(value))
        if (m) {
          month.value = m[2]
          const year = card.querySelector(".freeform-year"); if (year) year.value = m[1]
        }
        return
      }
      const el = card.querySelector("textarea, input[type='date']"); if (el) el.value = value
    } else if (type === "rating") {
      card.querySelectorAll(".rating-star").forEach((s, i) => {
        const on = i < Number(value); s.classList.toggle("active", on); s.textContent = on ? "★" : "☆"
      })
    }
  }

  _lockInputs(card) {
    card.querySelectorAll(".choice-list, .choice-grid, .rotate-wrap, .slider-wrap, .nps-slider, .prioritise-list, .rating-wrap, .freeform-wrap, .other-block")
        .forEach(el => { el.style.pointerEvents = "none" })
    card.querySelectorAll("textarea, input, button[data-other-target='btn']").forEach(el => { el.disabled = true })
  }

  _formatCorrect(type, c) {
    if (Array.isArray(c)) return c.join(", ")
    if (c && typeof c === "object") return Object.entries(c).map(([ k, v ]) => `${k}: ${v}`).join(", ")
    if (type === "rating") return `${c} ★`
    return String(c ?? "")
  }

  _renderScoreChip() {
    if (!this.hasScoreChipTarget || !this.quizValue || this._quizMax <= 0) return
    this.scoreChipTarget.classList.remove("hidden")
    this.scoreChipTarget.textContent = t("player.quiz_score", { score: this._quizScore, max: this._quizMax })
  }

  _labelQuizNav() {
    const pending = this._needsReveal(this.currentValue)
    if (this.hasNextBtnTarget)   this.nextBtnTarget.textContent   = pending ? t("player.quiz_check") : this._nextLabel
    if (this.hasFinishBtnTarget) this.finishBtnTarget.textContent = pending ? t("player.quiz_check") : this._finishLabel
  }

  _renderQuizScore() {
    if (!this.hasQuizScoreTarget || this._quizMax <= 0) return
    const pct = Math.round((this._quizScore / this._quizMax) * 100)
    this.quizScoreTarget.classList.remove("hidden")
    this.quizScoreTarget.innerHTML =
      `<div class="quiz-result-label">${this._esc(t("player.quiz_result_label"))}</div>` +
      `<div class="quiz-result-score">${this._quizScore}<span class="quiz-result-max">/${this._quizMax}</span></div>` +
      `<div class="quiz-result-pct">${pct}%</div>`
  }

  // ── Quiz: how you compare (anonymous score distribution) ─────────────────

  async _loadScores() {
    if (!this.scoresUrlValue) return
    if (this._scoresData) return this._renderScores(this._scoresData)
    this.scoresMetaTarget.textContent = t("player.compare_loading")
    try {
      const res  = await fetch(this.scoresUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Failed")
      this._scoresData = data
      this._renderScores(data)
    } catch (_) {
      this.scoresMetaTarget.textContent = t("player.compare_error")
    }
  }

  _renderScores(data) {
    const total = data.total || 0
    const mine  = this._quizScore
    const below = (data.distribution || []).filter(d => d.score < mine).reduce((s, d) => s + d.count, 0)
    const beat  = total > 0 ? Math.round((below / total) * 100) : 0
    this.scoresMetaTarget.textContent = total > 0
      ? t("player.quiz_compare_meta", { score: mine, max: data.max, beat, avg: data.average })
      : t("player.quiz_compare_empty")

    const list = this.scoresListTarget
    list.innerHTML = ""
    ;(data.distribution || []).forEach(d => {
      const pct = total > 0 ? Math.round((d.count / total) * 100) : 0
      list.appendChild(this._buildBar(t("player.quiz_score_bucket", { score: d.score, max: data.max }),
                                      d.count, pct, d.score === mine))
    })
    if ((data.per_question || []).length) {
      const head = document.createElement("div")
      head.style.cssText = "font-family:'Alata',sans-serif;font-size:13px;color:#fff;margin:8px 0 -4px;"
      head.textContent = t("player.quiz_per_question")
      list.appendChild(head)
      data.per_question.forEach(q => list.appendChild(this._buildBar(q.prompt || `#${q.index + 1}`, q.correct, q.pct, false)))
    }
  }

  // ── Tokenisation: running total, checkpoint card, final tally ────────────
  // A card's token config is public (it's rendered straight into the page,
  // unlike a quiz's hidden `correct` answer), so the running total is
  // computed entirely client-side — no grade-style round trip needed. The
  // server independently recomputes the authoritative total at
  // progress/submit time (PlayerController#apply_token_totals), and finish()
  // trusts that over this running tally, same as it does for quiz score.

  _initTokens() {
    this.tokenTypesValue.forEach(tt => { this._tokenTotals[tt.id] = 0 })
    this._renderTokenChip()
  }

  // Apply the token award for card `idx` to the running total, once. Called
  // right as the player advances past a card (Next/Finish) — going back to a
  // card already applied here can't re-earn, since _lockInputs makes its
  // widgets unresponsive and this method itself is idempotent per index.
  //
  // An UNANSWERED card is deliberately left alone when backNav is on. The
  // server has always taken this view — locked_merge keys off whether an answer
  // was actually stored, so it accepts a late answer to a card that was skipped
  // — but this method used to lock on the way past regardless, making the
  // client stricter than the server and quietly costing a respondent the points
  // for a question they meant to come back to.
  _applyTokenEarn(idx) {
    if (!this.tokenisationValue) return
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardAwardsTokens !== "true" || this._tokenLocked.has(idx)) return

    const key   = card.dataset.cardIndex
    const value = this._answers[key]?.value
    if (this.tokenBackNavValue && this._isBlankAnswer(value)) return

    this._tokenLocked.add(idx)
    const earned = this._computeEarned(card, card.dataset.cardType, value)
    Object.entries(earned).forEach(([id, amount]) => {
      this._tokenTotals[id] = (this._tokenTotals[id] || 0) + amount
    })

    this._lockInputs(card)
    this._renderTokenChip()
    if (this.tokenRevealValue) this._revealTokenEarn(card, earned)
  }

  // Mirrors TokenGrading.blank_value? — what the server treats as "not
  // answered", and so what back-navigation is allowed to return to.
  _isBlankAnswer(value) {
    if (value === null || value === undefined) return true
    if (typeof value === "string") return value.trim() === ""
    if (Array.isArray(value)) return value.length === 0
    if (typeof value === "object") return Object.keys(value).length === 0
    return false
  }

  // Show what THIS answer earned, not just the running total. The amount was
  // already being computed and thrown away into the total; this surfaces it,
  // reusing the quiz reveal's markup and animation so the two feel like one
  // idea rather than two.
  _revealTokenEarn(card, earned) {
    const host = card.querySelector(".split-right") || card
    host.querySelectorAll(".token-reveal").forEach(el => el.remove())

    const types = this.tokenTypesValue
    const rows  = Object.entries(earned)
      .filter(([ , amount ]) => Number(amount) > 0)
      .map(([ id, amount ]) => {
        const meta = types.find(t => String(t.id) === String(id))
        return `${meta?.icon || "★"} ${meta?.name || ""} +${amount}`.trim()
      })

    const box = document.createElement("div")
    box.className = `token-reveal ${rows.length ? "is-earned" : "is-none"}`
    const head = document.createElement("div")
    head.className = "token-reveal-head"
    head.textContent = rows.length ? t("player.tokens_earned") : t("player.tokens_earned_none")
    box.appendChild(head)
    if (rows.length) {
      const detail = document.createElement("div")
      detail.className = "token-reveal-rows"
      detail.textContent = rows.join(" · ")
      box.appendChild(detail)
    }
    host.appendChild(box)
  }

  // Client mirror of TokenGrading.earned — the token amounts a stored answer
  // value earns, as {token_id => amount}. `card.dataset.cardTokens` /
  // `cardTokenAward` carry this card's public config (see player/show.html.erb).
  _computeEarned(card, type, value) {
    const CHOICE_ONE  = [ "multiple_choice", "yes_no", "select_one_grid", "scenario" ]
    const CHOICE_MANY = [ "select_many", "select_many_grid" ]
    const FLAT        = [ "range", "nps", "rating", "open_ended", "prioritise" ]
    const sumHashes = (hashes) => {
      const out = {}
      hashes.forEach(h => { if (h) Object.entries(h).forEach(([k, v]) => { out[k] = (out[k] || 0) + Number(v || 0) }) })
      return out
    }
    const blank = (v) => v === null || v === undefined || v === "" || (Array.isArray(v) && v.length === 0)

    // Choice-shaped cards can opt into a flat award for completing the
    // question at all (mirrors TokenGrading.completion_award?), rather than
    // per chosen option — behaves exactly like the FLAT branch below.
    const completionAward = (CHOICE_ONE.includes(type) || CHOICE_MANY.includes(type)) &&
      card.dataset.cardTokenAwardMode === "completion"
    if (FLAT.includes(type) || completionAward) {
      if (blank(value)) return {}
      return this._parseJSON(card.dataset.cardTokenAward, {})
    }

    if (CHOICE_ONE.includes(type)) {
      const tokens = this._parseJSON(card.dataset.cardTokens, {})
      return tokens[String(value ?? "").trim()] || {}
    }
    if (CHOICE_MANY.includes(type)) {
      const tokens = this._parseJSON(card.dataset.cardTokens, {})
      return sumHashes((Array.isArray(value) ? value : []).map(v => tokens[String(v).trim()]))
    }
    if (type === "tap_card") {
      const tokens = this._parseJSON(card.dataset.cardTokens, {})
      if (typeof value !== "object" || !value) return {}
      return sumHashes(Object.entries(value).map(([statement, dir]) => tokens[statement]?.[dir]))
    }
    return {}
  }

  _parseJSON(str, fallback) {
    try {
      const parsed = JSON.parse(str || "null")
      return parsed === null || parsed === undefined ? fallback : parsed
    } catch (_) {
      return fallback
    }
  }

  _renderTokenChip() {
    if (!this.hasTokenScoreChipTarget || !this.tokenTypesValue.length) return
    this.tokenScoreChipTarget.classList.remove("hidden")
    this.tokenScoreChipTarget.innerHTML = this.tokenTypesValue.map(tt =>
      `<span class="token-score-pill">${this._esc(tt.icon)} ${this._tokenTotals[tt.id] || 0}</span>`
    ).join("")
  }

  // Points Checkpoint: when the active card is a checkpoint, fill in its
  // (otherwise-empty) body with the running totals — this is the only card
  // type whose content is entirely client-rendered.
  _maybeRenderCheckpoint(idx) {
    const card = this.cardTargets[idx]
    if (!card || card.dataset.cardType !== "token_checkpoint") return
    const body = card.querySelector(".token-checkpoint-body")
    if (!body || !this.tokenTypesValue.length) return
    body.innerHTML = this.tokenTypesValue.map(tt => `
      <div class="token-checkpoint-row">
        <span class="token-checkpoint-icon">${this._esc(tt.icon)}</span>
        <span class="token-checkpoint-amount">${this._tokenTotals[tt.id] || 0}</span>
        <span class="token-checkpoint-name">${this._esc(tt.name)}</span>
      </div>`).join("")
  }

  _renderTokenScore() {
    if (!this.hasTokenScoreTarget || !this.tokenTypesValue.length) return
    this.tokenScoreTarget.classList.remove("hidden")
    this.tokenScoreTarget.innerHTML =
      `<div class="token-result-label">${this._esc(t("player.tokens_result_label"))}</div>` +
      this.tokenTypesValue.map(tt => `
        <div class="token-result-row">
          <span class="token-result-icon">${this._esc(tt.icon)}</span>
          <span class="token-result-amount">${this._tokenTotals[tt.id] || 0}</span>
          <span class="token-result-name">${this._esc(tt.name)}</span>
        </div>`).join("")
  }

  _esc(s) {
    return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }
}
