import { Controller } from "@hotwired/stimulus"

// Types that expose a list of answer options in the details form
const OPTION_TYPES = new Set([
  "multiple_choice", "select_many",
  "select_one_grid", "select_many_grid",
  "tap_card"
])

// Types that expose min / max scale-label fields instead
const LABEL_TYPES = new Set(["range", "rating"])

// Default placeholder options (mirrors type_panel_controller.js)
const DEFAULT_OPTIONS = {
  range:            ["Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree"],
  rating:           ["Poor", "Fair", "Good", "Great", "Excellent"],
  multiple_choice:  ["Option A", "Option B", "Option C"],
  select_many:      ["Option A", "Option B", "Option C", "Option D"],
  yes_no:           ["Yes", "No"],
  select_one_grid:  ["A", "B", "C", "D"],
  select_many_grid: ["A", "B", "C", "D"],
  tap_card:         ["Statement 1", "Statement 2", "Statement 3"],
  open_ended:       [],
  welcome_card:     [],
}

export default class extends Controller {
  static targets = [
    "backdrop", "modal", "modalTitle",
    "stepChoice", "stepGenerating", "stepPickType", "stepDetails",
    "typeTile",
    "selectedTypeDisplay",
    "questionText", "charCount",
    "optionsArea", "optionsList",
    "labelsArea", "minLabel", "maxLabel",
    "addBtn",
    "cardsFeed",
    "errorMsg",
  ]

  static values = {
    generateUrl: String,
    renderUrl:   String,
  }

  connect() {
    this._selectedType = null
    this._escListener  = (e) => { if (e.key === "Escape") this.close() }
    this._typeMeta     = this._loadTypeMeta()
  }

  // ──────────────────────────────────────────────────────────
  // Open / Close
  // ──────────────────────────────────────────────────────────

  open(event) {
    event?.preventDefault()
    this._showStep("stepChoice")
    this._clearError()
    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)
  }

  close() {
    this.backdropTarget.hidden = true
    this._selectedType = null
    document.removeEventListener("keydown", this._escListener)
  }

  backdropClick(event) {
    if (event.target === this.backdropTarget) this.close()
  }

  // ──────────────────────────────────────────────────────────
  // Step 1: Choice screen
  // ──────────────────────────────────────────────────────────

  chooseGenerate(event) {
    event.preventDefault()
    this._clearError()
    this._showStep("stepGenerating")
    this._generateQuestion()
  }

  chooseBlank(event) {
    event.preventDefault()
    this._clearError()
    this._showStep("stepPickType")
  }

  // ──────────────────────────────────────────────────────────
  // Step B-1: Pick type
  // ──────────────────────────────────────────────────────────

  selectType(event) {
    const type = event.currentTarget.dataset.type
    this._selectedType = type

    // Highlight selected tile briefly, then advance
    this.typeTileTargets.forEach(t =>
      t.classList.toggle("selected", t.dataset.type === type)
    )
    setTimeout(() => this._goToDetails(type), 120)
  }

  backToChoice(event) {
    event.preventDefault()
    this._showStep("stepChoice")
  }

  // ──────────────────────────────────────────────────────────
  // Step B-2: Details form
  // ──────────────────────────────────────────────────────────

  backToPickType(event) {
    event.preventDefault()
    this._showStep("stepPickType")
  }

  onTextInput() {
    const len = this.questionTextTarget.value.length
    this.charCountTarget.textContent = `${len} / 100`
    const color = len > 100 ? "#FF1E6F" : len > 70 ? "#FFFA77" : "rgba(255,255,255,0.35)"
    this.charCountTarget.style.color = color
    this.addBtnTarget.disabled = len === 0
  }

  addOption(event) {
    event.preventDefault()
    const count = this.optionsListTarget.querySelectorAll(".aq-option-row").length
    const row = this._makeOptionRow(`Option ${count + 1}`)
    // Insert before the "Add option" button (always the last child of the list)
    this.optionsListTarget.lastElementChild.before(row)
    row.querySelector(".aq-option-input")?.focus()
  }

  removeOption(event) {
    event.preventDefault()
    event.currentTarget.closest(".aq-option-row")?.remove()
  }

  addToSurvey(event) {
    event.preventDefault()
    const card = this._collectCard()
    if (!card) return
    this.addBtnTarget.disabled = true
    this.addBtnTarget.textContent = "Adding…"
    this._renderAndInsert(card)
  }

  // ──────────────────────────────────────────────────────────
  // AI generation path
  // ──────────────────────────────────────────────────────────

  async _generateQuestion() {
    try {
      const res = await fetch(this.generateUrlValue, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": this._csrf(),
        },
        body: JSON.stringify({}),
      })
      const json = await res.json()
      if (!json.ok) throw new Error(json.error || "Generation failed")

      this._insertHTML(json.html)
      this._notifyEditor()
      this.close()
    } catch (err) {
      this._showStep("stepChoice")
      this._showError(`Couldn't generate a question: ${err.message}. Try again or start from blank.`)

    }
  }

  // ──────────────────────────────────────────────────────────
  // "Start from blank" — render via backend and insert
  // ──────────────────────────────────────────────────────────

  async _renderAndInsert(card) {
    try {
      const res = await fetch(this.renderUrlValue, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": this._csrf(),
        },
        body: JSON.stringify(card),
      })
      const json = await res.json()
      if (!json.ok) throw new Error(json.error || "Render failed")

      this._insertHTML(json.html)
      this._notifyEditor()
      this.close()
    } catch (err) {
      this.addBtnTarget.disabled = false
      this.addBtnTarget.textContent = "Add to survey →"
      this._showError(`Couldn't add the question: ${err.message}`)
    }
  }

  // ──────────────────────────────────────────────────────────
  // Step helpers
  // ──────────────────────────────────────────────────────────

  _showStep(stepName) {
    const steps = ["stepChoice", "stepGenerating", "stepPickType", "stepDetails"]
    steps.forEach(name => {
      const el = this[`${name}Target`]
      if (el) el.hidden = (name !== stepName)
    })
  }

  _goToDetails(type) {
    const meta = this._typeMeta[type] || {}

    // Update the type badge
    this.selectedTypeDisplayTarget.innerHTML =
      `<span style="font-size:20px;">${meta.picker_icon || ""}</span>` +
      `<span style="font-family:'Alata',sans-serif;">${meta.picker_name || type}</span>` +
      `<span style="font-size: var(--text-sm);color:rgba(255,255,255,0.5);">` +
      `${meta.picker_desc || ""}</span>`

    // Build options / labels UI
    if (OPTION_TYPES.has(type)) {
      this._buildOptionsUI(type)
      this.optionsAreaTarget.hidden = false
      this.labelsAreaTarget.hidden  = true
    } else if (LABEL_TYPES.has(type)) {
      const defaults = DEFAULT_OPTIONS[type] || []
      this.minLabelTarget.value = defaults[0] || ""
      this.maxLabelTarget.placeholder = defaults[0] || "Low end"
      this.maxLabelTarget.value = defaults[defaults.length - 1] || ""
      this.minLabelTarget.placeholder = defaults[defaults.length - 1] || "High end"
      this.labelsAreaTarget.hidden  = false
      this.optionsAreaTarget.hidden = true
    } else {
      this.optionsAreaTarget.hidden = true
      this.labelsAreaTarget.hidden  = true
    }

    // Reset question text
    this.questionTextTarget.value = ""
    this.charCountTarget.textContent = "0 / 100"
    this.charCountTarget.style.color  = "rgba(255,255,255,0.35)"
    this.addBtnTarget.disabled        = true
    this.addBtnTarget.textContent     = "Add to survey →"

    this._showStep("stepDetails")
  }

  _buildOptionsUI(type) {
    const defaults = DEFAULT_OPTIONS[type] || []
    const list = this.optionsListTarget
    list.innerHTML = ""
    defaults.forEach(opt => list.appendChild(this._makeOptionRow(opt)))

    // "Add option" button
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "aq-add-option-btn"
    btn.textContent = "＋ Add option"
    btn.dataset.action = "click->add-question#addOption"
    list.appendChild(btn)
  }

  _makeOptionRow(placeholder) {
    const row = document.createElement("div")
    row.className = "aq-option-row"

    const input = document.createElement("input")
    input.type = "text"
    input.className = "aq-option-input"
    input.placeholder = placeholder
    input.autocomplete = "off"

    const removeBtn = document.createElement("button")
    removeBtn.type = "button"
    removeBtn.className = "aq-remove-option-btn"
    removeBtn.title = "Remove option"
    removeBtn.textContent = "×"
    removeBtn.dataset.action = "click->add-question#removeOption"

    row.append(input, removeBtn)
    return row
  }

  // ──────────────────────────────────────────────────────────
  // Collect card object from the details form
  // ──────────────────────────────────────────────────────────

  _collectCard() {
    const type = this._selectedType
    if (!type) return null

    const text = this.questionTextTarget.value.trim()
    if (!text) return null

    const card = { type, text }

    if (OPTION_TYPES.has(type)) {
      const opts = Array.from(
        this.optionsListTarget.querySelectorAll(".aq-option-input")
      ).map(i => (i.value.trim() || i.placeholder)).filter(Boolean)
      if (opts.length) card.options = opts

    } else if (LABEL_TYPES.has(type)) {
      const defaults = DEFAULT_OPTIONS[type] || []
      const min = this.minLabelTarget.value.trim() || defaults[0] || ""
      const max = this.maxLabelTarget.value.trim() || defaults[defaults.length - 1] || ""
      // Range: emit full 5-point label array; Rating: emit min+max only
      if (type === "range") {
        card.options = defaults.map((d, i) => {
          if (i === 0) return min || d
          if (i === defaults.length - 1) return max || d
          return d
        })
      } else {
        card.options = [min, max].filter(Boolean)
      }
    }

    return card
  }

  // ──────────────────────────────────────────────────────────
  // DOM insertion
  // ──────────────────────────────────────────────────────────

  _insertHTML(html) {
    const feed = this.cardsFeedTarget
    if (!feed) return

    // Parse the returned HTML into a document fragment
    const tmp = document.createElement("div")
    tmp.innerHTML = html

    // The "Add question" trigger button wrapper is always the last child of the feed
    const trigger = feed.querySelector(".aq-trigger-btn")?.closest("div")
    if (trigger) {
      feed.insertBefore(tmp.firstElementChild, trigger)
    } else {
      feed.appendChild(tmp.firstElementChild)
    }

    // Scroll the new card into view
    const wraps = feed.querySelectorAll(".survey-card-wrap")
    wraps[wraps.length - 1]?.scrollIntoView({ behavior: "smooth", block: "nearest" })
  }

  _notifyEditor() {
    // Get the survey-editor Stimulus controller (scoped to the same root element)
    // and call refreshAll() + markDirty() directly.
    const editorController = this.application.getControllerForElementAndIdentifier(
      this.element, "survey-editor"
    )
    if (editorController) {
      editorController.refreshAll()
      editorController.markDirty()
    } else {
      // Fallback: dispatch input event which survey-editor listens for on the root div
      this.element.dispatchEvent(new Event("input", { bubbles: true }))
    }
  }

  // ──────────────────────────────────────────────────────────
  // Error display
  // ──────────────────────────────────────────────────────────

  _showError(msg) {
    if (this.hasErrorMsgTarget) {
      this.errorMsgTarget.textContent = msg
      this.errorMsgTarget.style.display = "block"
    }
  }

  _clearError() {
    if (this.hasErrorMsgTarget) {
      this.errorMsgTarget.textContent = ""
      this.errorMsgTarget.style.display = "none"
    }
  }

  // ──────────────────────────────────────────────────────────
  // Utilities
  // ──────────────────────────────────────────────────────────

  _loadTypeMeta() {
    try {
      return JSON.parse(document.getElementById("card-types")?.textContent || "{}")
    } catch (_) {
      return {}
    }
  }

  _csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
