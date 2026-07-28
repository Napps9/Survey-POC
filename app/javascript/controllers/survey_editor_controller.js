import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { analyzeCard, analyzeVerto, typeLabel } from "lib/verto_rules"

// Card types with no answer captured — mirrors CardTypes::NON_QUESTION_TYPES
// (app/lib/card_types.rb). welcome_card additionally stays pinned first (see
// moveCardUp / _updateMoveButtonStates), which token_checkpoint does not.
const NON_QUESTION_TYPES = [ "welcome_card", "token_checkpoint" ]

// Choice-shaped types — mirrors TokenGrading::CHOICE (app/lib/token_grading.rb).
// These default to a per-option token award but can opt into a flat award for
// completing the question at all (see setTokenAwardMode).
const CHOICE_TYPES = [ "multiple_choice", "select_many", "yes_no", "select_one_grid", "select_many_grid", "scenario" ]

export default class extends Controller {
  static targets = ["card", "saveButton", "status", "tab", "feed", "localeCode", "vertoScore", "scoreBoard", "panelLight"]
  static values  = {
    url: String, title: String, description: String,
    optimiseUrl: { type: String, default: "" },
    defaultLocale: { type: String, default: "en" },
    locales: { type: Array, default: [] },
    rtlLocales: { type: Array, default: [] },
    quiz: { type: Boolean, default: false },
    tokenisation: { type: Boolean, default: false },
    // Answer-branching: gates the per-option "go to…" route selects and their
    // serialization. logicConfig carries the static labels + end-screen list
    // the route dropdowns are built from (see refreshLogicTargets).
    logic: { type: Boolean, default: false },
    logicConfig: { type: Object, default: {} },
    live: { type: Boolean, default: false }
  }

  _saveTimer = null
  _dirty = false

  connect() {
    this._activeLocale = this.defaultLocaleValue
    this._eyebrows = this._loadEyebrows()
    this._seedStore()
    this.refreshAll()

    // Safety net for the 1.5s autosave debounce: if the page is hidden or
    // navigated away while an edit is still pending, flush it immediately so the
    // draft on the server never lags behind what's on screen (the cause of
    // "edits not saved" / draft-vs-preview drift). pagehide covers bfcache and
    // mobile; visibilitychange covers tab-switch/app-background.
    this._flushHandler = () => this.flushSave()
    window.addEventListener("pagehide", this._flushHandler)
    window.addEventListener("beforeunload", this._flushHandler)
    document.addEventListener("visibilitychange", this._visibilityHandler = () => {
      if (document.visibilityState === "hidden") this.flushSave()
    })
  }

  disconnect() {
    window.removeEventListener("pagehide", this._flushHandler)
    window.removeEventListener("beforeunload", this._flushHandler)
    document.removeEventListener("visibilitychange", this._visibilityHandler)
  }

  // Best-effort synchronous-ish flush of a pending autosave. Uses fetch with
  // keepalive so the request survives the page unload (sendBeacon can't send a
  // PATCH with a CSRF header). No-op when nothing is pending or the Verto is
  // live (the server rejects edits to a published Verto anyway).
  flushSave() {
    if (!this._dirty || this.liveValue) return
    if (!this.hasUrlValue || !this.urlValue) return
    clearTimeout(this._saveTimer)
    this._dirty = false
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      fetch(this.urlValue, {
        method: "PATCH",
        keepalive: true,
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify(this.serialize())
      })
    } catch (_) { /* unload path — nothing more we can do */ }
  }

  // ── Language tabs ──────────────────────────────────────
  // The DOM shows one locale at a time; per-card, per-locale text lives in
  // _store (keyed by the card element so add/delete/reorder stay consistent).
  // Structural edits are locked to the primary tab (CSS hides their controls
  // under .editing-translation), so translations only ever change text.

  switchLocale(event) {
    const locale = event.currentTarget.dataset.locale
    if (!locale || locale === this._activeLocale) return
    this._captureLocale(this._activeLocale)
    this._activeLocale = locale
    this._applyLocale(locale)
    if (this.hasTabTarget) {
      this.tabTargets.forEach(t => t.classList.toggle("is-active", t.dataset.locale === locale))
    }
    // Reflect the choice in the compact dropdown button.
    const btn = event.currentTarget
    if (this.hasLocaleCodeTarget && btn.dataset.code) this.localeCodeTarget.textContent = btn.dataset.code
    this.element.classList.toggle("editing-translation", locale !== this.defaultLocaleValue)
    if (this.hasFeedTarget) {
      this.feedTarget.setAttribute("dir", this.rtlLocalesValue.includes(locale) ? "rtl" : "ltr")
    }
    this.refreshAll()
  }

  // Per-locale "how to answer" captions (e.g. "Choose one"), keyed by locale
  // then card type — see application_helper.rb#card_eyebrows_i18n. Read once
  // at connect(); the blob is re-rendered by the server on every full page
  // load, same as _seedStore's source.
  _loadEyebrows() {
    try {
      return JSON.parse(document.getElementById("card-eyebrows-i18n")?.textContent || "{}")
    } catch (_) {
      return {}
    }
  }

  _seedStore() {
    this._store = new Map()
    let data = []
    try { data = JSON.parse(document.getElementById("survey-cards-i18n")?.textContent || "[]") } catch (_) {}
    const primary = this.defaultLocaleValue
    this.cardTargets.forEach((el, i) => {
      const c = data[i] || {}
      const entry = {}
      entry[primary] = this._normContent(c)
      const i18n = c.i18n || {}
      Object.keys(i18n).forEach(loc => { entry[loc] = this._normContent(i18n[loc]) })
      this._store.set(el, entry)
    })
  }

  _normContent(c) {
    c = c || {}
    return {
      text: c.text || "",
      description: c.description || "",
      options: Array.isArray(c.options) ? c.options.slice() : [],
      pages: Array.isArray(c.pages) ? c.pages.map(p => ({ id: p?.id || "", text: p?.text || "" })) : []
    }
  }

  // Option-label elements for a card, by type — the same nodes serialize reads.
  _optionEls(cardEl) {
    const sel = {
      multiple_choice: ".pick-text", select_many: ".pick-text", yes_no: ".pick-text",
      prioritise: ".choice-list-label",
      select_one_grid: ".choice-label", select_many_grid: ".choice-label",
      range: ".slider-label-text", nps: ".slider-label-text",
      rating: ".rating-label",
      tap_card: ".rotate-card span[contenteditable]",
      scenario: ".pick-text"
    }[cardEl.dataset.cardType]
    return sel ? Array.from(cardEl.querySelectorAll(sel)) : []
  }

  // Scenario narrative-page text elements, excluding the answer page (whose
  // options are read by _optionEls above) — id comes from the owning
  // .book-page, not the text node itself.
  _pageEls(cardEl) {
    return Array.from(cardEl.querySelectorAll(".book-page:not(.is-answer) .book-page-text"))
  }

  _readCard(cardEl) {
    return {
      text: cardEl.querySelector(".q-title, .activity-title")?.textContent.trim() || "",
      description: cardEl.querySelector(".q-subtitle, .activity-desc")?.textContent.trim() || "",
      options: this._optionEls(cardEl).map(el => el.textContent.trim()),
      pages: this._pageEls(cardEl).map(el => ({
        id: el.closest(".book-page")?.dataset.pageId || "",
        text: el.textContent.trim()
      }))
    }
  }

  _writeCard(cardEl, content, fallback, locale) {
    content = content || {}; fallback = fallback || {}
    const titleEl = cardEl.querySelector(".q-title, .activity-title")
    if (titleEl) titleEl.textContent = content.text || fallback.text || titleEl.textContent
    const descEl = cardEl.querySelector(".q-subtitle, .activity-desc")
    if (descEl) descEl.textContent = content.description || fallback.description || ""
    const opts = content.options || [], fopts = fallback.options || []
    this._optionEls(cardEl).forEach((el, k) => {
      el.textContent = (opts[k] && opts[k].trim()) || fopts[k] || el.textContent
    })
    // Pages align by id (not index) — a creator plausibly reorders narrative
    // pages after translating them, unlike options.
    const pages = content.pages || [], fpages = fallback.pages || []
    this._pageEls(cardEl).forEach(el => {
      const id = el.closest(".book-page")?.dataset.pageId || ""
      const tr = pages.find(p => p.id && p.id === id)
      const fb = fpages.find(p => p.id && p.id === id)
      el.textContent = (tr && tr.text.trim()) || (fb && fb.text) || el.textContent
    })
    // The "how to answer" caption isn't authored text (it's derived from the
    // card's type), so it isn't in the i18n store above — look it up straight
    // from the eyebrows blob for the locale being shown.
    const eyebrowEl = cardEl.querySelector(".q-eyebrow")
    if (eyebrowEl && locale) {
      const caption = (this._eyebrows[locale] || {})[cardEl.dataset.cardType]
      if (caption) eyebrowEl.textContent = caption
    }
    this.refreshCard(cardEl)
  }

  _captureLocale(locale) {
    this.cardTargets.forEach(el => {
      const entry = this._store.get(el) || {}
      entry[locale] = this._readCard(el)
      this._store.set(el, entry)
    })
  }

  _applyLocale(locale) {
    const primary = this.defaultLocaleValue
    this.cardTargets.forEach(el => {
      const entry = this._store.get(el) || {}
      this._writeCard(el, entry[locale], entry[primary], locale)
    })
  }

  // ── Rules of the Game — the live traffic-light analysis ──────────────────
  // Repaint every card's light plus the overall Verto score. Cheap enough
  // (~16 cards) to run wholesale on structural changes and locale switches.
  refreshAll() {
    this.renumberCards()
    this.cardTargets.forEach(c => this.refreshCard(c))
    this.refreshScore()
  }

  // ── Reorder ──────────────────────────────────────────────────────────────
  // Move a question up/down by swapping its slot with the neighbouring one. The
  // welcome card stays pinned first. No server call needed: autosave serialises
  // cards in document order, so reordering the DOM reorders the saved deck.

  moveCardUp(event) {
    event.stopPropagation()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    const slot = card?.closest(".card-slot")
    const prevSlot = slot?.previousElementSibling
    const prevCard = prevSlot?.querySelector("[data-survey-editor-target='card']")
    if (!slot || !prevSlot || !prevCard || prevCard.dataset.cardType === "welcome_card") return
    prevSlot.before(slot)
    this._afterReorder(card)
  }

  moveCardDown(event) {
    event.stopPropagation()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    const slot = card?.closest(".card-slot")
    const nextSlot = slot?.nextElementSibling
    if (!slot || !nextSlot || !nextSlot.classList.contains("card-slot")) return
    nextSlot.after(slot)
    this._afterReorder(card)
  }

  _afterReorder(card) {
    this.renumberCards()
    this.markDirty() // repaints the score + schedules the autosave that persists order
    card.scrollIntoView({ behavior: "smooth", block: "nearest" })
    card.classList.remove("card-flash")
    void card.offsetWidth // restart the pulse so the move reads as a move
    card.classList.add("card-flash")
    setTimeout(() => card.classList.remove("card-flash"), 1300)
  }

  // Re-stamp each card's number, progress bar and reorder-button state after a
  // structural change (insert / delete / reorder), so the "Card N" labels and
  // the data-card-num the score board jumps by stay consistent with the DOM.
  renumberCards() {
    const cards  = this.cardTargets
    const totalQ = cards.filter(c => !NON_QUESTION_TYPES.includes(c.dataset.cardType)).length
    let qIdx = 0
    cards.forEach((card, i) => {
      const num = i + 1
      card.dataset.cardNum = String(num)
      const numEl = card.querySelector("[data-role='card-number']")
      if (numEl) numEl.textContent = `Card ${num}`

      const isQ = !NON_QUESTION_TYPES.includes(card.dataset.cardType)
      if (isQ) qIdx++
      const pct  = isQ && totalQ > 0 ? Math.round((qIdx / totalQ) * 100) : 5
      const fill = card.querySelector(".panel-progress-fill")
      if (fill) fill.style.width = `${pct}%`
    })
    this._updateMoveButtonStates(cards)
    // Keep every route dropdown's target list in sync with the current deck.
    this.refreshLogicTargets()
  }

  // Disable "up" on the first movable card (and any card sitting just below the
  // welcome card) and "down" on the last, so the boundaries are obvious.
  _updateMoveButtonStates(cards) {
    cards.forEach(card => {
      const slot = card.closest(".card-slot")
      const up   = card.querySelector("[data-role='move-up']")
      const down = card.querySelector("[data-role='move-down']")
      if (up) {
        const prevCard = slot?.previousElementSibling?.querySelector("[data-survey-editor-target='card']")
        up.disabled = !prevCard || prevCard.dataset.cardType === "welcome_card"
      }
      if (down) {
        const nextSlot = slot?.nextElementSibling
        down.disabled = !nextSlot || !nextSlot.classList.contains("card-slot")
      }
    })
  }

  // The card object the analyzer scores: the text/options currently on screen
  // (so the score reflects the locale being edited) plus the Other toggle,
  // which counts toward a grid's even/≤10 rule.
  _cardData(cardEl) {
    const c = this._readCard(cardEl)
    return {
      type: cardEl.dataset.cardType,
      text: c.text,
      description: c.description,
      options: c.options,
      pages: c.pages,
      allowOther: cardEl.dataset.cardAllowOther === "true"
    }
  }

  refreshCard(card) {
    const light = card.querySelector("[data-role='card-light']")
    if (!light) {
      // Not a scored question (welcome/token-checkpoint) — hide the pinned
      // sidebar mirror if this is the card currently open in the panel.
      if (this.hasPanelLightTarget && this._typePanelActiveCard() === card) this.panelLightTarget.hidden = true
      return
    }
    this._paintCardLight(card, analyzeCard(this._cardData(card)))
  }

  _paintCardLight(card, result) {
    if (!result) return
    const light = card.querySelector("[data-role='card-light']")
    if (light) this._applyLightVisuals(light, result)

    // Mirror onto the pinned sidebar light so the score stays visible
    // whichever sub-tab (Question type / Tokenomics / Quiz mode) is open.
    if (this.hasPanelLightTarget && this._typePanelActiveCard() === card) {
      this._applyLightVisuals(this.panelLightTarget, result)
    }

    const panel = card.querySelector("[data-role='card-analysis']")
    if (panel) panel.innerHTML = this._panelHtml(t("editor.rules.title"), result.checks)
  }

  _applyLightVisuals(light, result) {
    light.hidden = false
    // classList (not className) so each element's own base classes — plain
    // .card-light inline, .card-light.panel-card-light pinned — survive.
    light.classList.remove("is-green", "is-yellow", "is-red")
    light.classList.add(`is-${result.rating}`)
    light.setAttribute("title", t("editor.rules.card_aria"))
    const word = light.querySelector("[data-role='card-light-word']")
    const score = light.querySelector("[data-role='card-light-score']")
    if (word) word.textContent = this._ratingWord(result.rating)
    if (score) score.textContent = result.score
  }

  // The card currently open in the right-hand panel (type-panel controller),
  // if any — shared root element, so we can reach across controllers.
  _typePanelActiveCard() {
    return this._typePanel()?.activeCardEl || null
  }

  _typePanel() {
    return this.application.getControllerForElementAndIdentifier(this.element, "type-panel")
  }

  // Clicking the pinned sidebar light jumps to the card's own analysis
  // breakdown in the feed (the pinned light has no room for the checklist).
  togglePanelCardAnalysis(event) {
    const card = this._typePanelActiveCard()
    const panel = card?.querySelector("[data-role='card-analysis']")
    if (!panel) return
    const open = panel.hidden
    panel.hidden = !open
    event.currentTarget.setAttribute("aria-expanded", String(open))
    if (open) card.scrollIntoView({ behavior: "smooth", block: "center" })
  }

  refreshScore() {
    if (!this.hasVertoScoreTarget) return
    const cardData = this.cardTargets.map(el => this._cardData(el))
    const result = analyzeVerto(cardData)

    // Paint the score tab. Use classList (not className) so the tab's own
    // classes — right-tab, verto-score, is-active — survive the repaint.
    const el = this.vertoScoreTarget
    el.classList.remove("is-green", "is-yellow", "is-red")
    el.classList.add(`is-${result.rating}`)
    const num  = el.querySelector("[data-role='verto-score-num']")
    const word = el.querySelector("[data-role='verto-score-word']")
    if (num)  num.textContent  = result.score
    if (word) word.textContent = this._ratingWord(result.rating)

    if (this.hasScoreBoardTarget) this._renderScoreBoard(result, cardData)
  }

  // Group every result into the red / amber / green sections of the score tab.
  // Whole-Verto checks ride along under a "Whole Verto" label; each card lands
  // in its own section carrying the checks that still need work.
  _renderScoreBoard(verto, cardData) {
    const board = { red: [], yellow: [], green: [] }
    // INFO is a non-scoring tip — surface it among the "could improve" items.
    const bucket = (rating) => board[rating === "info" ? "yellow" : rating]

    verto.checks.forEach(c => bucket(c.rating).push({ verto: true, text: c.text }))

    this.cardTargets.forEach((cardEl, i) => {
      const result = analyzeCard(cardData[i])
      if (!result) return // welcome cards aren't questions, so they aren't scored
      bucket(result.rating).push({
        verto: false,
        num: cardEl.dataset.cardNum,
        type: cardData[i].type,
        fixes: result.checks.filter(c => c.rating !== "green").map(c => c.text)
      })
    })

    this.scoreBoardTarget.innerHTML = ["red", "yellow", "green"]
      .map(rating => this._sectionHtml(rating, board[rating])).join("")
  }

  _sectionHtml(rating, items) {
    const head =
      `<div class="score-section-head"><span class="rule-dot"></span>` +
      `<span>${this._esc(this._ratingWord(rating))}</span>` +
      `<span class="score-count">${items.length}</span></div>`
    const body = items.length
      ? `<div class="score-rows">${items.map(it => this._scoreRowHtml(it)).join("")}</div>`
      : `<div class="score-empty">${this._esc(t("editor.rules.section_empty"))}</div>`
    return `<div class="score-section is-${rating}">${head}${body}</div>`
  }

  _scoreRowHtml(it) {
    if (it.verto) {
      return `<div class="score-row score-row-verto">` +
        `<div class="score-row-card">${this._esc(t("editor.rules.whole_verto"))}</div>` +
        `<div class="score-fix">${this._esc(it.text)}</div></div>`
    }
    const label = this._esc(`${t("editor.rules.card_n", { n: it.num })} · ${typeLabel(it.type)}`)
    const fixes = it.fixes.map(f => `<div class="score-fix">${this._esc(f)}</div>`).join("")
    const jump = `<button type="button" class="score-row-main" data-card-num="${this._esc(it.num)}" ` +
      `data-action="click->survey-editor#jumpToCard">` +
      `<div class="score-row-card">${label}</div>${fixes}</button>`
    // "Optimise" — an AI fix for the listed issues. Only on cards that have
    // fixes, and never while the Verto is live (editing is locked).
    const optimise = (it.fixes.length && this.optimiseUrlValue && !this.liveValue)
      ? `<button type="button" class="score-optimise-btn" data-card-num="${this._esc(it.num)}" ` +
        `data-issues="${this._esc(JSON.stringify(it.fixes))}" ` +
        `data-action="click->survey-editor#optimiseCard">✨ ${this._esc(t("editor.optimise"))}</button>`
      : ""
    return `<div class="score-row score-row-actionable">${jump}${optimise}</div>`
  }

  // AI-fix the issues on one card: send its current content + the flagged
  // issues, swap in the optimised version the server renders, and re-score.
  async optimiseCard(event) {
    event.stopPropagation()
    const btn  = event.currentTarget
    const num  = btn.dataset.cardNum
    const card = this.cardTargets.find(c => c.dataset.cardNum === num)
    if (!card || !this.optimiseUrlValue) return

    let issues = []
    try { issues = JSON.parse(btn.dataset.issues || "[]") } catch (_) { /* none */ }

    btn.disabled = true
    const original = btn.textContent
    btn.textContent = t("editor.optimising")
    card.classList.add("card-optimising")

    try {
      const res = await fetch(this.optimiseUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": this._csrf() },
        body: JSON.stringify({
          index:  this.cardTargets.indexOf(card),
          issues: issues,
          card:   { type: card.dataset.cardType, ...this._readCard(card) }
        })
      })
      const json = await res.json()
      if (!json.ok) throw new Error(json.error || "Optimise failed")
      this._replaceCard(card, json.html, json.card)
    } catch (err) {
      // Surface the failure where the click happened — a silent no-move reads
      // like a broken button — and keep the detail in the status flash.
      card.classList.remove("card-optimising")
      btn.disabled = false
      btn.textContent = original
      btn.classList.add("is-error")
      setTimeout(() => btn.classList.remove("is-error"), 2600)
      this.flash(t("editor.optimise_failed", { msg: err.message }), "text-hot-pink")
    }
  }

  // Replace a card element with freshly rendered HTML and reseed its store entry
  // (so language tabs + autosave keep its translations), then re-score + save.
  _replaceCard(oldEl, html, cardJson) {
    const tmp = document.createElement("div")
    tmp.innerHTML = (html || "").trim()
    const newEl = tmp.firstElementChild
    if (!newEl) return

    oldEl.replaceWith(newEl)
    this._typePanel()?.registerCard(newEl)

    this._store.delete(oldEl)
    const entry = {}
    entry[this.defaultLocaleValue] = this._normContent(cardJson)
    const i18n = cardJson.i18n || {}
    Object.keys(i18n).forEach(loc => { entry[loc] = this._normContent(i18n[loc]) })
    this._store.set(newEl, entry)
    // If a translation tab is active, show that language on the swapped-in card.
    if (this._activeLocale !== this.defaultLocaleValue) {
      this._writeCard(newEl, entry[this._activeLocale], entry[this.defaultLocaleValue], this._activeLocale)
    }

    this.refreshCard(newEl)
    this.refreshScore()
    this.markDirty()
    newEl.classList.remove("card-optimising")
    newEl.classList.add("card-flash")
    setTimeout(() => newEl.classList.remove("card-flash"), 1300)
  }

  _csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  // Scroll the feed to a card named in the score board and pulse it, so the
  // creator can go straight from "what to fix" to the card itself.
  jumpToCard(event) {
    const num = event.currentTarget.dataset.cardNum
    const card = this.cardTargets.find(c => c.dataset.cardNum === num)
    if (!card) return
    card.scrollIntoView({ behavior: "smooth", block: "center" })
    card.classList.remove("card-flash")
    void card.offsetWidth // restart the animation if the card was just pulsed
    card.classList.add("card-flash")
    setTimeout(() => card.classList.remove("card-flash"), 1300)
  }

  _panelHtml(title, checks, footer) {
    const rows = checks.map(c => (
      `<li class="rule-check is-${c.rating}"><span class="rule-dot"></span>` +
      `<span class="rule-text">${this._esc(c.text)}</span></li>`
    )).join("")
    return `<div class="rule-panel-title">${this._esc(title)}</div>` +
           `<ul class="rule-list">${rows}</ul>${footer || ""}`
  }

  _ratingWord(rating) {
    return t(`editor.rules.rating_${rating}`)
  }

  _esc(s) {
    return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
  }

  toggleCardAnalysis(event) {
    event.stopPropagation() // don't also select/apply the type underneath
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    const panel = card?.querySelector("[data-role='card-analysis']")
    if (!panel) return
    const open = panel.hidden
    panel.hidden = !open
    event.currentTarget.setAttribute("aria-expanded", String(open))
  }

  edit(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (card) this.refreshCard(card)
    this.markDirty()
  }

  deleteCard(event) {
    event.preventDefault()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!confirm(t("editor.delete_card_confirm"))) return
    card.remove()
    this.refreshAll()
    this.markDirty()
  }

  toggleOther(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!card) return
    const on = event.currentTarget.checked
    card.dataset.cardAllowOther = on ? "true" : "false"
    const wrap = card.querySelector(".other-cta-wrap")
    if (wrap) wrap.hidden = !on
    this.refreshCard(card)
    this.markDirty()
  }

  // Required is a pure data flag (no card-light effect), so just record it on
  // the wrap and autosave; serialize() carries it into the card JSON.
  toggleRequired(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!card) return
    card.dataset.cardRequired = event.currentTarget.checked ? "true" : "false"
    this.markDirty()
  }

  // Range-card reaction-animation theme. Record it on the wrap (serialize()
  // carries it into the card JSON) and swap the left-panel Lottie's URL set so
  // the preview updates live (lottie-player#urlsValueChanged re-renders).
  setRangeTheme(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!card) return
    const theme = event.currentTarget.value
    card.dataset.cardRangeTheme = theme
    const wrap = card.querySelector(".nps-lottie")
    const urls = this._rangeThemeUrls[theme]
    if (wrap && urls) wrap.dataset.lottiePlayerUrlsValue = JSON.stringify(urls)
    this.markDirty()
  }

  // { slug: [5 asset URLs] } from the editor's range-theme-picker blob, used to
  // swap the live preview when the theme changes.
  get _rangeThemeUrls() {
    if (this.__rangeThemeUrls) return this.__rangeThemeUrls
    const map = {}
    try {
      const data = JSON.parse(document.getElementById("range-theme-picker")?.textContent || "{}")
      ;(data.themes || []).forEach(th => { map[th.slug] = th.urls })
    } catch (_) { /* leave empty */ }
    this.__rangeThemeUrls = map
    return map
  }

  markDirty() {
    // Repaint the card being edited (or everything on a structural change) and
    // the overall score, so the lights track edits as they're typed.
    const active = document.activeElement?.closest?.("[data-survey-editor-target='card']")
    if (active) { this.refreshCard(active); this.refreshScore() } else { this.refreshAll() }

    this.flash(t("editor.unsaved"), "text-light-yellow")
    this._dirty = true
    clearTimeout(this._saveTimer)
    this._saveTimer = setTimeout(() => this._doSave(), 1500)
  }

  serialize() {
    // Sync whatever language is on screen, then build each card from the store:
    // top-level fields are the PRIMARY language; every other language goes under
    // i18n with options normalised to the primary's count/order (alignment).
    this._captureLocale(this._activeLocale)
    const primary   = this.defaultLocaleValue
    const secondary = this.localesValue.filter(l => l !== primary)

    const cards = this.cardTargets.map(card => {
      const type  = card.dataset.cardType
      const out   = { type }
      const entry = this._store.get(card) || {}
      const prim  = entry[primary] || this._readCard(card)

      // Stable card id — carried through every rebuild so answer-branching
      // routes (which target a card by cid, never index) never break. New cards
      // with no cid yet get one server-side (Survey.sanitize_cards_images!).
      if (card.dataset.cardCid) out.cid = card.dataset.cardCid

      out.text = (prim.text || "").trim()
      if (prim.description && prim.description.trim()) out.description = prim.description.trim()

      // A card's left panel holds a video OR a photo. Carry whichever it is —
      // plus the creator credit — through autosave, since the editor rebuilds
      // cards from the DOM and would otherwise drop these.
      const video = card.dataset.cardVideo
      const image = card.dataset.cardImage
      if (video) {
        out.video = video
        if (card.dataset.cardVideoPoster) out.video_poster = card.dataset.cardVideoPoster
      } else if (image) {
        out.image = image
      }
      if (video || image) {
        const credit    = card.dataset.cardImageCredit
        const creditUrl = card.dataset.cardImageCreditUrl
        if (credit) out.image_credit = credit
        if (creditUrl) out.image_credit_url = creditUrl
      }
      if (card.dataset.cardAllowOther === "true") out.allow_other = true
      if (card.dataset.cardRequired === "true") out.required = true

      // Structural flags the DOM never re-derives — an open_ended input
      // flavour (e.g. the birth-date "month" picker) and the demographic
      // marker — so autosave doesn't silently strip them the first time an
      // otherwise-unrelated field on the card is edited.
      if (card.dataset.cardInput) out.input = card.dataset.cardInput
      if (card.dataset.cardDemographic === "true") out.demographic = true

      // Common Question provenance — the ids that let results aggregate the
      // same question across Vertos. Nothing in the editor displays them, so
      // without carrying them here the first autosave would quietly orphan a
      // question the wizard (or the library picker) attached, and the rollup
      // would stop counting it with no visible symptom.
      if (card.dataset.cardCommonQuestionId) {
        out.common_question_id = Number(card.dataset.cardCommonQuestionId)
      }
      if (card.dataset.cardCommonQuestionSetId) {
        out.common_question_set_id = Number(card.dataset.cardCommonQuestionSetId)
      }

      // Range cards carry the reaction-animation theme picked in the editor.
      // Server-side sanitize drops it if it isn't a known slug on a range card.
      if (type === "range" && card.dataset.cardRangeTheme) out.range_theme = card.dataset.cardRangeTheme
      // ...and the slider layout toggle (auto/horizontal/vertical), same gate.
      if (type === "range" && card.dataset.cardSliderAxis) out.slider_axis = card.dataset.cardSliderAxis

      // Range labels are POSITIONAL — each one names a fixed stop on a 5-point
      // track, so a blank is an unnamed stop, not an option to discard.
      // Dropping it would shorten the scale and shuffle every label after it
      // (the server re-spreads what it receives). Every other type treats a
      // blank as "not an option" and drops it as before.
      const trimmedOpts = (prim.options || []).map(o => (o || "").trim())
      const primOpts    = type === "range" ? trimmedOpts : trimmedOpts.filter(Boolean)
      if (primOpts.length) out.options = primOpts

      // Scenario narrative pages, in document order — id-and-text pairs so
      // translations (below) can align by id instead of position.
      const primPages = type === "scenario"
        ? (prim.pages || []).map(p => ({ id: p.id || "", text: (p.text || "").trim() })).filter(p => p.text)
        : []
      if (primPages.length) out.pages = primPages

      // tap_card statement backgrounds (populated by AssetPopulator, or
      // generated/picked in the editor). Carried through autosave regardless
      // of the card's CURRENT type — not just while it's tap_card — so
      // switching away and back restores them instead of the server silently
      // losing them on the next save while some other type is active.
      // Survey.sanitize_cards_images! has no type gate on option_images
      // (unlike pages/range_theme), so it's safe to carry this through even
      // on a card that isn't tap_card right now. Only bound the array to the
      // current option count while tap_card is actually active — primOpts is
      // some OTHER type's options otherwise, and truncating against it would
      // destroy statements this card isn't even showing right now.
      try {
        const optImgs = JSON.parse(card.dataset.cardOptionImages || "[]")
        if (Array.isArray(optImgs) && optImgs.length) {
          out.option_images = type === "tap_card" ? optImgs.slice(0, primOpts.length) : optImgs
        }
      } catch (_) { /* ignore malformed */ }

      // Quiz: a card with a marked correct answer carries `correct` (+ optional
      // `explanation`); leaving it unmarked keeps the card as a measurement Q.
      if (this.quizValue) {
        const correct = this._readCorrect(card, type)
        if (this._hasCorrect(correct)) {
          out.correct = correct
          const expl = this._quizScope(card).querySelector("[data-quiz-explanation]")?.value?.trim()
          if (expl) out.explanation = expl
        }
      }

      // Tokenisation: choice/tap_card carry per-option/per-direction `tokens`;
      // scale/open/prioritise carry a flat `token_award`. Leaving every amount
      // at 0 keeps the card unawarded (TokenGrading.awarding? stays false).
      // Choice-shaped cards can opt into a flat award too (token_award_mode).
      if (this.tokenisationValue) {
        const { tokens, token_award } = this._readTokens(card, type)
        if (tokens && Object.keys(tokens).length) out.tokens = tokens
        if (token_award && Object.keys(token_award).length) out.token_award = token_award
        if (CHOICE_TYPES.includes(type) && this._tokenAwardMode(card) === "completion") {
          out.token_award_mode = "completion"
        }
      }

      // Answer-branching: single-pick cards carry per-option `routes` (+ an
      // optional `default`). Leaving every option on "Continue" keeps the card
      // linear (LogicGraph.routing? stays false).
      if (this.logicValue) {
        const logic = this._readLogic(card, type)
        if (this._hasLogic(logic)) out.logic = logic
      }
      // The unconditional flow pointer (any card type), set by the flow map to
      // chain branch cards and rejoin. Carried on the wrap so it round-trips.
      const nextRaw = card.dataset.cardNext
      if (nextRaw) {
        try {
          const n = JSON.parse(nextRaw)
          if (n && ((n.card && n.card !== "") || (n.end && n.end !== ""))) out.next = n
        } catch (_) { /* drop malformed */ }
      }
      // Optional branch name (flow map), stored on the lane's entry card.
      const laneLabel = (card.dataset.cardLaneLabel || "").trim()
      if (laneLabel) out.lane_label = laneLabel

      const i18n = {}
      secondary.forEach(loc => {
        const t = entry[loc]
        if (!t) return
        const tEntry = {}
        if ((t.text || "").trim()) tEntry.text = t.text.trim()
        if ((t.description || "").trim()) tEntry.description = t.description.trim()
        if (primOpts.length) {
          const topts = t.options || []
          tEntry.options = primOpts.map((p, k) => ((topts[k] || "").trim()) || p)
        }
        if (primPages.length) {
          const tpages = t.pages || []
          tEntry.pages = primPages.map(p => {
            const match = tpages.find(tp => tp.id && tp.id === p.id)
            return { id: p.id, text: (match && match.text.trim()) || p.text }
          })
        }
        if (Object.keys(tEntry).length) i18n[loc] = tEntry
      })
      if (Object.keys(i18n).length) out.i18n = i18n

      return out
    })

    return { title: this.titleValue, description: this.descriptionValue, cards }
  }

  // ── Quiz: correct-answer marking ─────────────────────────────────────────

  _hasCorrect(c) {
    if (c === null || c === undefined || c === "") return false
    if (Array.isArray(c)) return c.length > 0
    if (typeof c === "object") return Object.keys(c).length > 0
    return true
  }

  // Quiz-correct-block / token-award-block may currently be relocated into
  // the sidebar's Tokenomics/Quiz mode sub-tabs (see type-panel controller's
  // selectCard) rather than sitting inside `card` — look them up by the
  // registry (element reference, location-independent) so reads/writes keep
  // working wherever the block currently lives. Falls back to searching
  // `card` itself for a block that was never relocated (e.g. no card has
  // been selected in the panel yet).
  _quizScope(card)  { return this._typePanel()?.quizBlockFor(card)  || card }
  _tokenScope(card) { return this._typePanel()?.tokenBlockFor(card) || card }
  // The routing selects live in a block that the type panel relocates into the
  // sidebar's Branching tab for the selected card, so read/write them wherever
  // that block currently sits (falling back to the card if never relocated).
  _logicScope(card) { return this._typePanel()?.logicBlockFor(card) || card }

  // Public: the branching-block scope for a card by cid — used by the flow map
  // to drive the same route selects after they've been relocated to the sidebar.
  logicScopeForCid(cid) {
    const wrap = document.querySelector(`.survey-card-wrap[data-card-cid="${CSS.escape(cid)}"]`)
    return wrap ? this._logicScope(wrap) : null
  }

  // The marked correct answer for a card, in the shape QuizGrading expects.
  _readCorrect(card, type) {
    const labelOf = item => {
      if (type === "yes_no") return (item.dataset.canonical || "").trim()
      const lbl = item.querySelector(".pick-text, .choice-label")
      return (lbl?.textContent.trim()) || (item.dataset.canonical || "").trim()
    }
    switch (type) {
      case "multiple_choice": case "yes_no": case "select_one_grid": case "scenario": {
        const el = card.querySelector('[data-picker-target="item"][data-correct="true"]')
        return el ? labelOf(el) : null
      }
      case "select_many": case "select_many_grid":
        return Array.from(card.querySelectorAll('[data-picker-target="item"][data-correct="true"]'))
                    .map(labelOf).filter(Boolean)
      case "tap_card": {
        const map = {}
        this._quizScope(card).querySelectorAll(".quiz-tap-row").forEach(row => {
          const dir = row.dataset.correctDir
          if (dir === "yes" || dir === "no") map[(row.dataset.statement || "").trim()] = dir
        })
        return map
      }
      case "range": case "nps": case "rating": {
        const v = this._quizScope(card).querySelector("[data-quiz-correct]")?.value
        return (v === undefined || v === null || v === "") ? null : Number(v)
      }
      case "open_ended": {
        const ta = this._quizScope(card).querySelector("[data-quiz-accepted]")
        return ta ? ta.value.split("\n").map(s => s.trim()).filter(Boolean) : null
      }
      default: return null
    }
  }

  // ── Tokenisation: per-option / per-card token-amount marking ─────────────

  // Every non-zero token-amount input inside `container`, as {token_id => n}.
  _tokenAmounts(container) {
    const out = {}
    container.querySelectorAll(".token-amount-input").forEach(input => {
      const id = input.dataset.tokenId
      const n  = parseInt(input.value, 10)
      if (id && n) out[id] = n
    })
    return out
  }

  // This card's token config, in the shape TokenGrading expects: `tokens` for
  // choice/tap_card (keyed by canonical option/statement), `token_award` for
  // the flat-award types.
  // Which award mode a choice-shaped card is currently set to — whichever
  // [data-token-mode-section] is visible (toggled by setTokenAwardMode).
  _tokenAwardMode(card) {
    const completion = this._tokenScope(card).querySelector('[data-token-mode-section="completion"]')
    return completion && !completion.hidden ? "completion" : "per_answer"
  }

  _readTokens(card, type) {
    switch (type) {
      case "multiple_choice": case "select_many": case "yes_no":
      case "select_one_grid": case "select_many_grid": case "scenario": {
        // Relocated into the sidebar's Tokenomics tab (see
        // _card_component.html.erb) — not inline on the option itself, so
        // read via the token scope, not `card` directly.
        const scope = this._tokenScope(card)
        if (this._tokenAwardMode(card) === "completion") {
          const row = scope.querySelector('[data-token-mode-section="completion"] .token-award-row')
          return { token_award: row ? this._tokenAmounts(row) : {} }
        }
        // One .token-award-row per option.
        const tokens = {}
        scope.querySelectorAll('[data-token-mode-section="per_answer"] .token-award-row[data-canonical]').forEach(row => {
          const label  = (row.dataset.canonical || "").trim()
          const inputs = row.querySelector(".token-inputs")
          if (!label || !inputs) return
          const amt = this._tokenAmounts(inputs)
          if (Object.keys(amt).length) tokens[label] = amt
        })
        return { tokens }
      }
      case "tap_card": {
        const tokens = {}
        this._tokenScope(card).querySelectorAll(".token-tap-row").forEach(row => {
          const statement = (row.dataset.statement || "").trim()
          if (!statement) return
          const dirs = {}
          row.querySelectorAll(".token-inputs").forEach(dirBlock => {
            const dir = dirBlock.dataset.direction
            const amt = this._tokenAmounts(dirBlock)
            if (dir && Object.keys(amt).length) dirs[dir] = amt
          })
          if (Object.keys(dirs).length) tokens[statement] = dirs
        })
        return { tokens }
      }
      case "range": case "nps": case "rating": case "open_ended": case "prioritise": {
        const row = this._tokenScope(card).querySelector(".token-award-row")
        return { token_award: row ? this._tokenAmounts(row) : {} }
      }
      default:
        return {}
    }
  }

  // ── Answer-branching: per-option routing ────────────────────────────────

  // This card's routing config, in the shape LogicGraph expects. Reads the
  // inline per-option <select data-logic-route> plus the card's default
  // ("otherwise") select. Only single-pick types route this pass.
  _readLogic(card, type) {
    if (type !== "multiple_choice" && type !== "yes_no" && type !== "scenario") return null
    const scope = this._logicScope(card)
    const routes = []
    scope.querySelectorAll("[data-logic-route][data-canonical]").forEach(sel => {
      const label = (sel.dataset.canonical || "").trim()
      const to    = this._logicTargetFromValue(sel.value)
      if (label && to) routes.push({ match: { op: "equals", value: label }, to })
    })
    const logic = {}
    if (routes.length) logic.routes = routes
    const defSel = scope.querySelector("[data-logic-default]")
    const def    = defSel ? this._logicTargetFromValue(defSel.value) : null
    if (def) logic.default = def
    return this._hasLogic(logic) ? logic : null
  }

  _hasLogic(logic) {
    return !!(logic && ((Array.isArray(logic.routes) && logic.routes.length) || logic.default))
  }

  // Decode a route select value: "" (continue/linear), "card:<cid>", "end:<id>".
  _logicTargetFromValue(value) {
    if (!value) return null
    if (value.startsWith("end:"))  { const id  = value.slice(4); return id  ? { end: id }   : null }
    if (value.startsWith("card:")) { const cid = value.slice(5); return cid ? { card: cid } : null }
    return null
  }

  // Rebuild the <option> list of every inline route select from the CURRENT
  // deck, so targets always reflect live reorders/inserts/deletes. Each select
  // keeps its chosen value via data-logic-selected; a target that has since
  // vanished falls back to "Continue". Cheap enough (~16 cards) to run whole.
  refreshLogicTargets() {
    if (!this.logicValue) return
    const selects = this.element.querySelectorAll("[data-logic-route], [data-logic-default]")
    if (!selects.length) return
    const cfg   = this.logicConfigValue || {}
    const ends  = Array.isArray(cfg.ends) ? cfg.ends : []
    const cards = this.cardTargets.map(c => ({
      cid: c.dataset.cardCid,
      num: c.dataset.cardNum,
      label: (c.querySelector(".q-title, .activity-title")?.textContent || "").trim().slice(0, 40)
    }))
    selects.forEach(sel => {
      // The block may have been relocated into the sidebar's Branching tab, so
      // fall back to the block's own owner-cid when it's no longer in a card.
      const ownerCid = sel.closest("[data-survey-editor-target='card']")?.dataset.cardCid
                    || sel.closest("[data-logic-block]")?.dataset.ownerCid
      const chosen   = sel.dataset.logicSelected || ""
      sel.innerHTML  = ""
      sel.appendChild(this._logicOption("", cfg.continue || "Continue (default flow)"))
      ends.forEach(e => sel.appendChild(this._logicOption(`end:${e.id}`, `${cfg.finishPrefix || "Finish"} · ${e.label}`)))
      cards.forEach(c => {
        if (!c.cid || c.cid === ownerCid) return
        sel.appendChild(this._logicOption(`card:${c.cid}`, c.label ? `→ Card ${c.num}: ${c.label}` : `→ Card ${c.num}`))
      })
      sel.value = chosen
      if (sel.value !== chosen) { sel.value = ""; sel.dataset.logicSelected = "" } // target gone ⇒ fall through
    })
  }

  _logicOption(value, label) {
    const o = document.createElement("option")
    o.value = value
    o.textContent = label
    return o
  }

  // Persist the creator's route choice so a later refresh keeps it, then save.
  logicRouteChanged(event) {
    const sel = event.currentTarget
    sel.dataset.logicSelected = sel.value
    this.markDirty()
  }

  // Keep a routable card's Branching-tab rows in step with its live answer
  // options: one row per option, in document order, each remembering its chosen
  // route. Fires when options are added/removed (card-editor:changed) or an
  // option label is edited (focusout). Routes are keyed by the option label (its
  // canonical), so each chosen target is carried across the rebuild by a stable
  // per-option uid — surviving renames — with the row label and the select's
  // canonical updated to the option's current text.
  syncBranchingEvent(event) {
    const card = event.target?.closest?.("[data-survey-editor-target='card']")
    if (!card) return
    // On focusout, only react to leaving an option label — not every field blur.
    if (event.type === "focusout" && !event.target.closest?.(".pick-text")) return
    this.syncBranchingFor(card)
  }

  syncBranchingFor(cardEl) {
    if (!this.logicValue || !cardEl) return
    // yes_no answers are fixed; multiple_choice and scenario both have dynamic
    // option lists whose branching rows need to stay in step with them.
    if (!["multiple_choice", "scenario"].includes(cardEl.dataset.cardType)) return
    const scope = this._logicScope(cardEl)
    const list  = scope.querySelector(".logic-branch-list")
    if (!list) return

    // Prior chosen route per option — by uid (survives renames), then by label,
    // then by position (covers a rename made before any uid was assigned).
    const byUid = new Map(), byLabel = new Map(), byIndex = []
    list.querySelectorAll(".logic-branch-row").forEach(row => {
      const sel = row.querySelector("[data-logic-route]")
      if (!sel) return
      const val = sel.dataset.logicSelected || sel.value || ""
      byIndex.push(val)
      if (row.dataset.optUid) byUid.set(row.dataset.optUid, val)
      if (sel.dataset.canonical) byLabel.set(sel.dataset.canonical, val)
    })

    // Rebuild one row per current option, in order, carrying each route across.
    list.textContent = ""
    this._optionEls(cardEl).forEach((optEl, i) => {
      const label = optEl.textContent.trim()
      if (!label) return
      let uid = optEl.dataset.optUid
      if (!uid) { uid = String(this._optUidSeq = (this._optUidSeq || 0) + 1); optEl.dataset.optUid = uid }
      const val = byUid.has(uid) ? byUid.get(uid)
                : byLabel.has(label) ? byLabel.get(label)
                : (byIndex[i] || "")
      list.appendChild(this._branchRow(uid, label, val))
    })
    this.refreshLogicTargets() // fill the (possibly new) selects' option lists + values
  }

  // One "AnswerLabel → [route select]" row, matching shared/_logic_branch_block.
  _branchRow(uid, label, selected) {
    const row = document.createElement("li")
    row.className = "logic-branch-row"
    row.dataset.optUid = uid
    const answer = document.createElement("span")
    answer.className = "logic-branch-answer"
    answer.textContent = label
    const arrow = document.createElement("span")
    arrow.className = "logic-branch-arrow"
    arrow.setAttribute("aria-hidden", "true")
    arrow.textContent = "→"
    const sel = document.createElement("select")
    sel.className = "logic-route-select"
    sel.setAttribute("data-logic-route", "")
    sel.dataset.canonical = label
    sel.dataset.logicSelected = selected || ""
    sel.dataset.action = "input->survey-editor#logicRouteChanged change->survey-editor#logicRouteChanged"
    sel.onclick = (e) => e.stopPropagation()
    row.append(answer, arrow, sel)
    return row
  }

  // Mark / unmark an option as correct. Single-choice acts like a radio.
  toggleCorrect(event) {
    event.stopPropagation()
    const btn  = event.currentTarget
    const item = btn.closest('[data-picker-target="item"]')
    if (!item) return
    const turnOn = item.dataset.correct !== "true"
    if (btn.dataset.pickerMode === "single") {
      item.closest(".choice-list, .choice-grid")
          ?.querySelectorAll('[data-picker-target="item"]')
          .forEach(el => { el.dataset.correct = "false" })
    }
    item.dataset.correct = turnOn ? "true" : "false"
    this.markDirty()
  }

  // Set / clear the correct swipe direction for one tap_card statement.
  toggleTapCorrect(event) {
    event.stopPropagation()
    const btn = event.currentTarget
    const row = btn.closest(".quiz-tap-row")
    if (!row) return
    row.dataset.correctDir = (row.dataset.correctDir === btn.dataset.dir) ? "" : btn.dataset.dir
    row.querySelectorAll(".quiz-tap-btn").forEach(b => b.classList.toggle("is-on", b.dataset.dir === row.dataset.correctDir))
    this.markDirty()
  }

  // Switch a choice-shaped card between awarding tokens per chosen option
  // and a flat award just for completing the question (see
  // TokenGrading.completion_award?). Both sections stay in the DOM (this
  // just swaps which is visible) so switching back and forth never loses
  // amounts already entered on either side.
  setTokenAwardMode(event) {
    const btn   = event.currentTarget
    const mode  = btn.dataset.mode
    const block = btn.closest(".token-award-block")
    if (!block) return
    block.querySelectorAll(".token-mode-btn").forEach(b => b.classList.toggle("is-active", b.dataset.mode === mode))
    block.querySelectorAll("[data-token-mode-section]").forEach(sec => {
      sec.hidden = sec.dataset.tokenModeSection !== mode
    })
    this.markDirty()
  }

  async save(event) {
    event?.preventDefault()
    if (this.hasSaveButtonTarget) this.saveButtonTarget.disabled = true
    this.flash(t("editor.saving"), "text-smoke/60")
    clearTimeout(this._saveTimer)
    await this._doSave()
    if (this.hasSaveButtonTarget) this.saveButtonTarget.disabled = false
  }

  async _doSave() {
    if (!this.hasUrlValue || !this.urlValue) return
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const res = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify(this.serialize())
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const json = await res.json()
      this._dirty = false
      // The save itself succeeded, but the server may have silently dropped an
      // oversized/invalid image (sanitize_cards_images! nils it out rather than
      // erroring) — tell the editor instead of just showing "Saved".
      if (Array.isArray(json.warnings) && json.warnings.length) {
        this.flash(t("editor.save_warning"), "text-hot-pink")
      } else {
        this.flash(t("editor.saved", { time: new Date(json.updated_at).toLocaleTimeString() }), "text-aquamarine")
      }
    } catch (err) {
      this.flash(t("editor.save_failed", { msg: err.message }), "text-hot-pink")
    }
  }

  flash(text, klass) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.className = `text-xs ${klass}`
  }

  // Save-status relay for the in-feed consent/thank-you gate cards —
  // gate_cards_controller persists them via update_settings rather than the
  // card autosave, so their saves surface in the same top-left status pill.
  gateStatus(event) {
    const { state, time, msg } = event.detail || {}
    if (state === "saving")     this.flash(t("editor.saving"), "text-smoke/60")
    else if (state === "saved") this.flash(t("editor.saved", { time }), "text-aquamarine")
    else if (state === "error") this.flash(t("editor.save_failed", { msg }), "text-hot-pink")
  }
}
