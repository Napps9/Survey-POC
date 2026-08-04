import { Controller } from "@hotwired/stimulus"
import { defaultOptionsFor, OPTION_TYPES, LABEL_TYPES } from "lib/default_options"
import { t } from "lib/i18n"


export default class extends Controller {
  static targets = [
    "backdrop", "modal", "modalTitle",
    "stepChoice", "stepGenerating", "stepPickType", "stepDetails", "stepLibrary",
    "libraryChoice", "libraryItem",
    "typeTile",
    "selectedTypeDisplay",
    "questionText", "charCount",
    "optionsArea", "optionsList",
    "labelsArea", "minLabel", "maxLabel",
    "addBtn",
    "cardsFeed",
    "errorMsg",
    "detailsError",
    "demographicTile",
  ]

  static values = {
    generateUrl: String,
    renderUrl:   String,
    demographicUrl: String,
  }

  connect() {
    this._selectedType = null
    this._escListener  = (e) => { if (e.key === "Escape") this.close() }
    this._typeMeta     = this._loadTypeMeta()
    // Bumped on every close/reopen so a generate/render request that's still
    // in flight when the user dismisses the modal can tell it's stale and
    // skip inserting a card the user never asked to keep.
    this._requestToken = 0
  }

  // ──────────────────────────────────────────────────────────
  // Open / Close
  // ──────────────────────────────────────────────────────────

  open(event) {
    event?.preventDefault()
    // Remember which card the CTA sits under, so the new question is inserted
    // right after it (rather than always at the end of the deck).
    this._insertAfterSlot = event?.currentTarget?.closest(".card-slot") || null
    this._showStep("stepChoice")
    this._clearError()
    this._syncDemographicTiles()
    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)
  }

  close() {
    this.backdropTarget.hidden = true
    this._setSelectedType(null)
    this._enableLibraryItems()
    // Reset to the first step so a stale details view can never resurface
    // without a fresh type pick when the modal is reopened.
    this._showStep("stepChoice")
    document.removeEventListener("keydown", this._escListener)
    this._requestToken++ // invalidate any generate/render request still in flight
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
  // Step L: pick a saved Common Question from the org's library
  // ──────────────────────────────────────────────────────────

  chooseLibrary(event) {
    event.preventDefault()
    this._clearError()
    this._showStep("stepLibrary")
  }

  pickLibraryQuestion(event) {
    event.preventDefault()
    let card
    try {
      card = JSON.parse(event.currentTarget.dataset.card || "null")
    } catch (_) {
      card = null
    }
    if (!card) {
      this._showStep("stepChoice")
      this._showError(t("editor.add_question.saved_read_failed"))
      return
    }

    // Same insert path as "Start from blank": the server renders the card row
    // (stamping a cid) and we splice the HTML in. The common_question_id rides
    // along inside `card` untouched, so the new card stays tied to the library
    // question for results aggregation.
    event.currentTarget.disabled = true
    this._renderAndInsert(card)
  }

  // ──────────────────────────────────────────────────────────
  // Step B-1: Pick type
  // ──────────────────────────────────────────────────────────

  selectType(event) {
    const type = event.currentTarget.dataset.type
    this._setSelectedType(type)

    // Highlight selected tile briefly, then advance
    this.typeTileTargets.forEach(t =>
      t.classList.toggle("selected", t.dataset.type === type)
    )
    setTimeout(() => this._goToDetails(type), 120)
  }

  // Persist the picked type in the DOM as well as on the instance. Stimulus
  // controllers lose their instance state when they disconnect/reconnect (a
  // Turbo cache restore, a re-scan of this root element), which would leave
  // `_selectedType` null while the details step is still on screen — so
  // "Add to survey" wrongly reported "Enter a question first". The data
  // attribute survives a reconnect, so _collectCard can always recover it.
  _setSelectedType(type) {
    this._selectedType = type
    if (this.hasStepDetailsTarget) this.stepDetailsTarget.dataset.selectedType = type || ""
  }

  backToChoice(event) {
    event.preventDefault()
    this._showStep("stepChoice")
    this._syncDemographicTiles()
  }

  // ──────────────────────────────────────────────────────────
  // Opt-in demographic questions (Heritage / Neurodiversity)
  // ──────────────────────────────────────────────────────────

  // One of each per Verto: a tile greys out while the deck holds a card with
  // its demographic_key. Recomputed from the live feed on every open, so a
  // client-side delete re-enables the tile without a reload.
  _syncDemographicTiles() {
    this.demographicTileTargets.forEach(tile => {
      const key = tile.dataset.demographicKey
      tile.disabled = !!this.cardsFeedTarget?.querySelector(`[data-card-demographic-key="${key}"]`)
    })
  }

  // Insert the registry-built card via the server (it arrives fully formed
  // and localised — no details step). Appended at the END of the deck, the
  // demographics convention, by nulling the insert anchor.
  async addDemographic(event) {
    event.preventDefault()
    const tile = event.currentTarget
    const key = tile.dataset.demographicKey
    tile.disabled = true
    const token = this._requestToken
    try {
      const res = await fetch(this.demographicUrlValue, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": this._csrf(),
        },
        body: JSON.stringify({ key }),
      })
      const json = await res.json()
      if (!json.ok) throw new Error(json.error || t("editor.add_question.render_failed"))
      if (token !== this._requestToken) return // modal closed/reopened — drop it

      this._insertAfterSlot = null
      this._insertHTML(json.html, json.card)
      this._notifyEditor()
      this.close()
    } catch (err) {
      if (token !== this._requestToken) return
      tile.disabled = false
      this._showError(t("editor.add_question.add_failed", { message: err.message }))
    }
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
    // Clear the "enter a question" hint once they start typing. The button stays
    // enabled throughout — validation happens on click (see addToSurvey) so a
    // disabled-with-no-explanation button never reads as "Add doesn't work".
    if (len > 0) this._clearDetailsError()
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
    if (!card) {
      this._showDetailsError(t("editor.add_question.enter_question_first"))
      this.questionTextTarget?.focus()
      return
    }
    this._clearDetailsError()
    this.addBtnTarget.disabled = true
    this.addBtnTarget.textContent = t("editor.add_question.adding")
    this._renderAndInsert(card)
  }

  // ──────────────────────────────────────────────────────────
  // AI generation path
  // ──────────────────────────────────────────────────────────

  async _generateQuestion() {
    const token = this._requestToken
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
      if (!json.ok) throw new Error(json.error || t("editor.add_question.generation_failed"))
      if (token !== this._requestToken) return // modal was closed/reopened — drop it

      this._insertHTML(json.html, json.card)
      this._notifyEditor()
      this.close()
    } catch (err) {
      if (token !== this._requestToken) return
      this._showStep("stepChoice")
      this._showError(`Couldn't generate a question: ${err.message}. Try again or start from blank.`)

    }
  }

  // ──────────────────────────────────────────────────────────
  // "Start from blank" — render via backend and insert
  // ──────────────────────────────────────────────────────────

  async _renderAndInsert(card) {
    const token = this._requestToken
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
      if (!json.ok) throw new Error(json.error || t("editor.add_question.render_failed"))
      if (token !== this._requestToken) return // modal was closed/reopened — drop it

      this._insertHTML(json.html, json.card)
      this._notifyEditor()
      this.close()
    } catch (err) {
      if (token !== this._requestToken) return
      this.addBtnTarget.disabled = false
      this.addBtnTarget.textContent = t("editor.add_question.add_to_survey")
      this._enableLibraryItems() // the library path disables the tile it picked
      this._showError(t("editor.add_question.add_failed", { message: err.message }))
    }
  }

  _enableLibraryItems() {
    this.libraryItemTargets.forEach(el => { el.disabled = false })
  }

  // ──────────────────────────────────────────────────────────
  // Step helpers
  // ──────────────────────────────────────────────────────────

  _showStep(stepName) {
    const steps = ["stepChoice", "stepGenerating", "stepPickType", "stepDetails", "stepLibrary"]
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
      const defaults = defaultOptionsFor(type)
      this.minLabelTarget.value = defaults[0] || ""
      this.maxLabelTarget.placeholder = defaults[0] || t("editor.add_question.low_end")
      this.maxLabelTarget.value = defaults[defaults.length - 1] || ""
      this.minLabelTarget.placeholder = defaults[defaults.length - 1] || t("editor.add_question.high_end")
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
    this.addBtnTarget.disabled        = false
    this.addBtnTarget.textContent     = t("editor.add_question.add_to_survey")
    this._clearDetailsError()

    this._showStep("stepDetails")
  }

  _showDetailsError(msg) {
    if (!this.hasDetailsErrorTarget) return
    this.detailsErrorTarget.textContent = msg
    this.detailsErrorTarget.style.display = "block"
  }

  _clearDetailsError() {
    if (!this.hasDetailsErrorTarget) return
    this.detailsErrorTarget.textContent = ""
    this.detailsErrorTarget.style.display = "none"
  }

  _buildOptionsUI(type) {
    const defaults = defaultOptionsFor(type)
    const list = this.optionsListTarget
    list.innerHTML = ""
    defaults.forEach(opt => list.appendChild(this._makeOptionRow(opt)))

    // "Add option" button
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "aq-add-option-btn"
    btn.textContent = `＋ ${t("card.add_option")}`
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
    removeBtn.title = t("editor.add_question.remove_option")
    removeBtn.textContent = "×"
    removeBtn.dataset.action = "click->add-question#removeOption"

    row.append(input, removeBtn)
    return row
  }

  // ──────────────────────────────────────────────────────────
  // Collect card object from the details form
  // ──────────────────────────────────────────────────────────

  _collectCard() {
    // Fall back to the DOM-persisted type if the instance state was reset by a
    // controller reconnect while the details step stayed open (see
    // _setSelectedType).
    const type = this._selectedType ||
                 (this.hasStepDetailsTarget ? this.stepDetailsTarget.dataset.selectedType : "")
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
      const defaults = defaultOptionsFor(type)
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

  _insertHTML(html, cardJson = null) {
    const feed = this.cardsFeedTarget
    if (!feed) return

    // The server returns a bare .survey-card-wrap — rail included, so the new
    // card arrives with its own Add-question CTA and behaves like every
    // other: reorderable and insert-after-able. Wrap it in a slot.
    const tmp = document.createElement("div")
    tmp.innerHTML = (html || "").trim()
    const card = tmp.firstElementChild
    if (!card) return

    const slot = document.createElement("div")
    slot.className = "card-slot"
    slot.appendChild(card)

    // Insert after the card whose CTA was clicked, else append to the end.
    const anchor = this._insertAfterSlot
    if (anchor && anchor.parentNode === feed) {
      anchor.after(slot)
      // Inserting below a flow member joins the flow — the new card lands
      // inside the flow's visual run, so membership should match.
      const anchorFlowId = anchor.querySelector("[data-survey-editor-target='card']")?.dataset.cardFlowId
      if (anchorFlowId) card.dataset.cardFlowId = anchorFlowId
    } else {
      feed.appendChild(slot)
    }

    // Register this new card's quiz-correct-block / token-award-block (if
    // rendered) so the sidebar's Tokenomics/Quiz mode sub-tabs can find them
    // once it's selected — see type-panel controller's registerCard.
    const editorController = this.application.getControllerForElementAndIdentifier(
      this.element, "type-panel"
    )
    editorController?.registerCard(card)

    // Put the inverse on the undo stack. Skipping this didn't just make "add"
    // un-undoable — it left ⌘Z pointing at an older delete or reorder, so the
    // next undo silently reverted something else.
    const editor = this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")
    // Seed the translation store BEFORE the undo entry, so an undo of a
    // generated card does not leave a store entry pointing at a detached node.
    editor?.seedCardStore?.(card, cardJson)
    editor?.recordCardInsertion(slot)

    card.scrollIntoView({ behavior: "smooth", block: "nearest" })
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
