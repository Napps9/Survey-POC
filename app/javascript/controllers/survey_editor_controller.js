import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { analyzeCard, analyzeVerto, typeLabel } from "lib/verto_rules"

export default class extends Controller {
  static targets = ["card", "saveButton", "status", "tab", "feed", "localeFlag", "localeCode", "vertoScore", "scoreBoard"]
  static values  = {
    url: String, title: String, description: String,
    optimiseUrl: { type: String, default: "" },
    defaultLocale: { type: String, default: "en" },
    locales: { type: Array, default: [] },
    rtlLocales: { type: Array, default: [] },
    quiz: { type: Boolean, default: false },
    live: { type: Boolean, default: false }
  }

  _saveTimer = null
  _dirty = false

  connect() {
    this._activeLocale = this.defaultLocaleValue
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
    if (this.hasLocaleFlagTarget && btn.dataset.flag) this.localeFlagTarget.textContent = btn.dataset.flag
    if (this.hasLocaleCodeTarget && btn.dataset.code) this.localeCodeTarget.textContent = btn.dataset.code
    this.element.classList.toggle("editing-translation", locale !== this.defaultLocaleValue)
    if (this.hasFeedTarget) {
      this.feedTarget.setAttribute("dir", this.rtlLocalesValue.includes(locale) ? "rtl" : "ltr")
    }
    this.refreshAll()
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
      options: Array.isArray(c.options) ? c.options.slice() : []
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
      tap_card: ".rotate-card span[contenteditable]"
    }[cardEl.dataset.cardType]
    return sel ? Array.from(cardEl.querySelectorAll(sel)) : []
  }

  _readCard(cardEl) {
    return {
      text: cardEl.querySelector(".q-title, .activity-title")?.textContent.trim() || "",
      description: cardEl.querySelector(".q-subtitle, .activity-desc")?.textContent.trim() || "",
      options: this._optionEls(cardEl).map(el => el.textContent.trim())
    }
  }

  _writeCard(cardEl, content, fallback) {
    content = content || {}; fallback = fallback || {}
    const titleEl = cardEl.querySelector(".q-title, .activity-title")
    if (titleEl) titleEl.textContent = content.text || fallback.text || titleEl.textContent
    const descEl = cardEl.querySelector(".q-subtitle, .activity-desc")
    if (descEl) descEl.textContent = content.description || fallback.description || ""
    const opts = content.options || [], fopts = fallback.options || []
    this._optionEls(cardEl).forEach((el, k) => {
      el.textContent = (opts[k] && opts[k].trim()) || fopts[k] || el.textContent
    })
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
      this._writeCard(el, entry[locale], entry[primary])
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
    const totalQ = cards.filter(c => c.dataset.cardType !== "welcome_card").length
    let qIdx = 0
    cards.forEach((card, i) => {
      const num = i + 1
      card.dataset.cardNum = String(num)
      const numEl = card.querySelector("[data-role='card-number']")
      if (numEl) numEl.textContent = `Card ${num}`

      const isQ = card.dataset.cardType !== "welcome_card"
      if (isQ) qIdx++
      const pct  = isQ && totalQ > 0 ? Math.round((qIdx / totalQ) * 100) : 5
      const fill = card.querySelector(".panel-progress-fill")
      if (fill) fill.style.width = `${pct}%`
    })
    this._updateMoveButtonStates(cards)
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
      allowOther: cardEl.dataset.cardAllowOther === "true"
    }
  }

  refreshCard(card) {
    const light = card.querySelector("[data-role='card-light']")
    if (!light) return // welcome cards aren't questions, so they aren't scored
    this._paintCardLight(card, analyzeCard(this._cardData(card)))
  }

  _paintCardLight(card, result) {
    const light = card.querySelector("[data-role='card-light']")
    if (!light || !result) return
    light.hidden = false
    light.className = `card-light is-${result.rating}`
    light.setAttribute("title", t("editor.rules.card_aria"))
    const word = light.querySelector("[data-role='card-light-word']")
    const score = light.querySelector("[data-role='card-light-score']")
    if (word) word.textContent = this._ratingWord(result.rating)
    if (score) score.textContent = result.score
    const panel = card.querySelector("[data-role='card-analysis']")
    if (panel) panel.innerHTML = this._panelHtml(t("editor.rules.title"), result.checks)
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

    this._store.delete(oldEl)
    const entry = {}
    entry[this.defaultLocaleValue] = this._normContent(cardJson)
    const i18n = cardJson.i18n || {}
    Object.keys(i18n).forEach(loc => { entry[loc] = this._normContent(i18n[loc]) })
    this._store.set(newEl, entry)
    // If a translation tab is active, show that language on the swapped-in card.
    if (this._activeLocale !== this.defaultLocaleValue) {
      this._writeCard(newEl, entry[this._activeLocale], entry[this.defaultLocaleValue])
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

      const primOpts = (prim.options || []).map(o => (o || "").trim()).filter(Boolean)
      if (primOpts.length) out.options = primOpts

      // tap_card statement backgrounds (populated by AssetPopulator). Carry
      // them through autosave so editing other fields doesn't wipe the art.
      if (type === "tap_card") {
        try {
          const optImgs = JSON.parse(card.dataset.cardOptionImages || "[]")
          if (Array.isArray(optImgs) && optImgs.length) {
            out.option_images = optImgs.slice(0, primOpts.length)
          }
        } catch (_) { /* ignore malformed */ }
      }

      // Quiz: a card with a marked correct answer carries `correct` (+ optional
      // `explanation`); leaving it unmarked keeps the card as a measurement Q.
      if (this.quizValue) {
        const correct = this._readCorrect(card, type)
        if (this._hasCorrect(correct)) {
          out.correct = correct
          const expl = card.querySelector("[data-quiz-explanation]")?.value?.trim()
          if (expl) out.explanation = expl
        }
      }

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

  // The marked correct answer for a card, in the shape QuizGrading expects.
  _readCorrect(card, type) {
    const labelOf = item => {
      if (type === "yes_no") return (item.dataset.canonical || "").trim()
      const lbl = item.querySelector(".pick-text, .choice-label")
      return (lbl?.textContent.trim()) || (item.dataset.canonical || "").trim()
    }
    switch (type) {
      case "multiple_choice": case "yes_no": case "select_one_grid": {
        const el = card.querySelector('[data-picker-target="item"][data-correct="true"]')
        return el ? labelOf(el) : null
      }
      case "select_many": case "select_many_grid":
        return Array.from(card.querySelectorAll('[data-picker-target="item"][data-correct="true"]'))
                    .map(labelOf).filter(Boolean)
      case "tap_card": {
        const map = {}
        card.querySelectorAll(".quiz-tap-row").forEach(row => {
          const dir = row.dataset.correctDir
          if (dir === "yes" || dir === "no") map[(row.dataset.statement || "").trim()] = dir
        })
        return map
      }
      case "range": case "nps": case "rating": {
        const v = card.querySelector("[data-quiz-correct]")?.value
        return (v === undefined || v === null || v === "") ? null : Number(v)
      }
      case "open_ended": {
        const ta = card.querySelector("[data-quiz-accepted]")
        return ta ? ta.value.split("\n").map(s => s.trim()).filter(Boolean) : null
      }
      default: return null
    }
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
      this.flash(t("editor.saved", { time: new Date(json.updated_at).toLocaleTimeString() }), "text-aquamarine")
    } catch (err) {
      this.flash(t("editor.save_failed", { msg: err.message }), "text-hot-pink")
    }
  }

  flash(text, klass) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.className = `text-xs ${klass}`
  }
}
