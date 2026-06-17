import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"
import { analyzeCard, analyzeVerto, typeLabel } from "lib/verto_rules"

export default class extends Controller {
  static targets = ["card", "saveButton", "status", "tab", "feed", "localeFlag", "localeCode", "vertoScore", "scoreBoard"]
  static values  = {
    url: String, title: String, description: String,
    defaultLocale: { type: String, default: "en" },
    locales: { type: Array, default: [] },
    rtlLocales: { type: Array, default: [] }
  }

  _saveTimer = null

  connect() {
    this._activeLocale = this.defaultLocaleValue
    this._seedStore()
    this.refreshAll()
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
    this.cardTargets.forEach(c => this.refreshCard(c))
    this.refreshScore()
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
    return `<button type="button" class="score-row" data-card-num="${this._esc(it.num)}" ` +
      `data-action="click->survey-editor#jumpToCard">` +
      `<div class="score-row-card">${label}</div>${fixes}</button>`
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

      const image = card.dataset.cardImage
      if (image) out.image = image
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
