import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

const TYPE_BOUNDS = {
  tap_card:         { min: 3, max: 5 },
  multiple_choice:  { min: 3, max: 5 },
  select_many:      { min: 3, max: 5 },
  rating:           { min: 3, max: 5 },
  range:            { min: 3, max: 5 },
  nps:              { min: 4, max: 11 },
  select_one_grid:  { min: 2, max: 10, even: true },
  select_many_grid: { min: 2, max: 10, even: true }
}
const COUNTABLE = new Set([
  "multiple_choice", "select_many", "select_one_grid", "select_many_grid",
  "tap_card", "range", "rating", "nps", "yes_no", "open_ended"
])
const TEXT_TARGET = 70
const TEXT_HARD_MAX = 100
const OPTION_HARD_MAX = 20
const QUESTIONS_MIN = 10
const QUESTIONS_MAX = 15

export default class extends Controller {
  static targets = ["card", "summary", "saveButton", "status", "tab", "feed", "localeFlag", "localeCode"]
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

  refreshAll() {
    this.cardTargets.forEach(c => this.refreshCard(c))
    this.refreshSummary()
  }

  refreshCard(card) {
    const type = card.dataset.cardType
    const textEl = card.querySelector("[data-role='text']")
    if (textEl) this.setCharWarning(textEl, TEXT_HARD_MAX, TEXT_TARGET)

    const descEl = card.querySelector("[data-role='description']")
    if (descEl) this.setCharWarning(descEl, TEXT_HARD_MAX, TEXT_TARGET)

    card.querySelectorAll("[data-role='option']").forEach(o =>
      this.setCharWarning(o, OPTION_HARD_MAX, OPTION_HARD_MAX)
    )

    const bounds = TYPE_BOUNDS[type]
    if (bounds) {
      const optionEls = card.querySelectorAll("[data-role='option-row']")
      const count = optionEls.length
      const addBtn = card.querySelector("[data-action*='addOption']")
      const removeBtns = card.querySelectorAll("[data-action*='removeOption']")
      if (addBtn) addBtn.disabled = count >= bounds.max
      removeBtns.forEach(b => b.disabled = count <= bounds.min)

      const status = card.querySelector("[data-role='option-status']")
      if (status) {
        const messages = []
        messages.push(`${count} of ${bounds.min}-${bounds.max}`)
        if (bounds.even && count % 2 !== 0) messages.push("must be even")
        const ok = count >= bounds.min && count <= bounds.max && (!bounds.even || count % 2 === 0)
        status.textContent = messages.join(" · ")
        status.className = "text-xs " + (ok ? "text-smoke/50" : "text-hot-pink font-medium")
      }
    }
  }

  refreshSummary() {
    if (!this.hasSummaryTarget) return
    const questionCount = this.cardTargets.filter(c => COUNTABLE.has(c.dataset.cardType)).length
    const ok = questionCount >= QUESTIONS_MIN && questionCount <= QUESTIONS_MAX
    this.summaryTarget.textContent = `${questionCount} Q (${QUESTIONS_MIN}-${QUESTIONS_MAX})`
    this.summaryTarget.className = "display text-sm tracking-widest " + (ok ? "text-aquamarine" : "text-hot-pink")
  }

  setCharWarning(el, hardMax, target) {
    const len = (el.textContent || "").length
    el.dataset.len = len
    let color = "border-transparent"
    if (len > hardMax) color = "border-hot-pink"
    else if (len > target) color = "border-light-yellow"
    el.classList.remove("border-transparent", "border-hot-pink", "border-light-yellow")
    el.classList.add(color)

    const counter = el.parentElement.querySelector("[data-role='char-counter']")
    if (counter) {
      counter.textContent = `${len}/${hardMax}`
      counter.className = "text-xs " + (len > hardMax ? "text-hot-pink font-medium" : len > target ? "text-light-yellow" : "text-smoke/40")
    }
  }

  edit(event) {
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (card) this.refreshCard(card)
    this.markDirty()
  }

  addOption(event) {
    event.preventDefault()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    const list = card.querySelector("[data-role='option-list']")
    const template = card.querySelector("[data-role='option-template']")
    if (!list || !template) return
    const node = template.content.firstElementChild.cloneNode(true)
    list.appendChild(node)
    this.refreshCard(card)
    this.markDirty()
    node.querySelector("[data-role='option']")?.focus()
  }

  removeOption(event) {
    event.preventDefault()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    event.currentTarget.closest("[data-role='option-row']").remove()
    this.refreshCard(card)
    this.markDirty()
  }

  deleteCard(event) {
    event.preventDefault()
    const card = event.currentTarget.closest("[data-survey-editor-target='card']")
    if (!confirm(t("js.editor.delete_card_confirm"))) return
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
    this.markDirty()
  }

  markDirty() {
    this.flash(t("js.editor.unsaved"), "text-light-yellow")
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

      const primOpts = (prim.options || []).map(o => (o || "").trim()).filter(Boolean)
      if (primOpts.length) out.options = primOpts

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
    this.flash(t("js.editor.saving"), "text-smoke/60")
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
      this.flash(t("js.editor.saved", { time: new Date(json.updated_at).toLocaleTimeString() }), "text-aquamarine")
    } catch (err) {
      this.flash(t("js.editor.save_failed", { msg: err.message }), "text-hot-pink")
    }
  }

  flash(text, klass) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.className = `text-xs ${klass}`
  }
}
