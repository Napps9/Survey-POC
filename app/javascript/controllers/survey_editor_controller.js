import { Controller } from "@hotwired/stimulus"

const TYPE_BOUNDS = {
  tap_card:         { min: 3, max: 5 },
  multiple_choice:  { min: 3, max: 5 },
  select_many:      { min: 3, max: 5 },
  rating:           { min: 3, max: 5 },
  range:            { min: 3, max: 5 },
  select_one_grid:  { min: 2, max: 10, even: true },
  select_many_grid: { min: 2, max: 10, even: true }
}
const COUNTABLE = new Set([
  "multiple_choice", "select_many", "select_one_grid", "select_many_grid",
  "tap_card", "range", "rating", "yes_no", "open_ended"
])
const TEXT_TARGET = 70
const TEXT_HARD_MAX = 100
const OPTION_HARD_MAX = 20
const QUESTIONS_MIN = 10
const QUESTIONS_MAX = 15

export default class extends Controller {
  static targets = ["card", "summary", "title", "surveyDescription", "saveButton", "status"]
  static values  = { id: Number, url: String }

  connect() {
    this.refreshAll()
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
        status.className = "text-xs " + (ok ? "text-gray-500" : "text-red-600 font-medium")
      }
    }
  }

  refreshSummary() {
    if (!this.hasSummaryTarget) return
    const questionCount = this.cardTargets.filter(c => COUNTABLE.has(c.dataset.cardType)).length
    const ok = questionCount >= QUESTIONS_MIN && questionCount <= QUESTIONS_MAX
    this.summaryTarget.textContent = `${questionCount} questions (rule: ${QUESTIONS_MIN}-${QUESTIONS_MAX})`
    this.summaryTarget.className = "text-sm font-medium " + (ok ? "text-emerald-700" : "text-red-700")
  }

  setCharWarning(el, hardMax, target) {
    const len = (el.textContent || "").length
    el.dataset.len = len
    let color = "border-transparent"
    if (len > hardMax) color = "border-red-500"
    else if (len > target) color = "border-amber-400"
    el.classList.remove("border-transparent", "border-red-500", "border-amber-400")
    el.classList.add(color)

    const counter = el.parentElement.querySelector("[data-role='char-counter']")
    if (counter) {
      counter.textContent = `${len}/${hardMax}`
      counter.className = "text-xs " + (len > hardMax ? "text-red-600 font-medium" : len > target ? "text-amber-600" : "text-gray-400")
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
    if (!confirm("Delete this card?")) return
    card.remove()
    this.refreshAll()
    this.markDirty()
  }

  markDirty() {
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = "Unsaved changes"
      this.statusTarget.className = "text-xs text-amber-600"
    }
  }

  serialize() {
    const cards = this.cardTargets.map(card => {
      const type = card.dataset.cardType
      const text = card.querySelector("[data-role='text']")?.textContent.trim() || ""
      const description = card.querySelector("[data-role='description']")?.textContent.trim() || ""
      const options = Array.from(card.querySelectorAll("[data-role='option']"))
        .map(o => o.textContent.trim()).filter(Boolean)
      const out = { type, text }
      if (description) out.description = description
      if (options.length) out.options = options
      return out
    })

    return {
      title: this.titleTarget.textContent.trim(),
      description: this.surveyDescriptionTarget.textContent.trim(),
      cards
    }
  }

  async save(event) {
    event.preventDefault()
    if (!this.hasUrlValue || !this.urlValue) {
      this.flash("Nothing to save (no survey id)", "text-red-600")
      return
    }
    this.saveButtonTarget.disabled = true
    this.flash("Saving…", "text-gray-500")
    try {
      const res = await fetch(this.urlValue, {
        method: "PATCH",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify(this.serialize())
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const json = await res.json()
      this.flash(`Saved ${new Date(json.updated_at).toLocaleTimeString()}`, "text-emerald-700")
    } catch (err) {
      this.flash(`Save failed: ${err.message}`, "text-red-600")
    } finally {
      this.saveButtonTarget.disabled = false
    }
  }

  flash(text, klass) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.className = `text-xs ${klass}`
  }
}
