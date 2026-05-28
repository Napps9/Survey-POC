import { Controller } from "@hotwired/stimulus"

// Enables a "Select" mode on a section of dashboard cards. Toggling the mode
// reveals a checkbox on each card, and the action bar appears as soon as
// anything is selected. Submitting builds an ad-hoc form that DELETEs to
// `actionUrlValue` with an `ids[]` payload — the controller action archives
// or hard-destroys based on which URL was wired up.
//
// In select mode, the entire card body becomes the click target — single-
// clicking anywhere on a card toggles its checkbox, and pressing-and-
// dragging across multiple cards selects (or deselects) them in one sweep.
// Native UI inside cards (Edit / Results / Delete links, the corner
// checkbox label) keeps its own click behaviour.
//
// Usage:
//   <div data-controller="bulk-select"
//        data-bulk-select-action-url-value="/surveys/bulk_archive"
//        data-bulk-select-confirm-template-value="Delete {count} Vertos?"
//        data-bulk-select-selected-template-value="{count} selected">
//     <button data-bulk-select-target="toggle"
//             data-action="bulk-select#toggle">Select</button>
//     <!-- cards, each containing: -->
//     <input type="checkbox" data-bulk-select-target="checkbox"
//            data-survey-id="42" data-action="bulk-select#update">
//     <div data-bulk-select-target="bar" hidden>
//       <span data-bulk-select-target="count"></span>
//       <button data-action="bulk-select#submit">Delete</button>
//       <button data-action="bulk-select#cancel">Cancel</button>
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["toggle", "checkbox", "bar", "count"]
  static values  = {
    actionUrl:        String,
    confirmTemplate:  { type: String, default: "Delete {count} Vertos?" },
    selectedTemplate: { type: String, default: "{count} selected" },
    selectLabel:      { type: String, default: "Select" },
    doneLabel:        { type: String, default: "Done" }
  }

  connect() {
    this.element.classList.remove("is-selecting")
    if (this.hasBarTarget) this.barTarget.hidden = true
    this._onPointerDown = this.onPointerDown.bind(this)
    this._onPointerMove = this.onPointerMove.bind(this)
    this._onPointerUp   = this.onPointerUp.bind(this)
    this.element.addEventListener("pointerdown", this._onPointerDown)
  }

  disconnect() {
    this.element.removeEventListener("pointerdown", this._onPointerDown)
    document.removeEventListener("pointermove", this._onPointerMove)
    document.removeEventListener("pointerup",   this._onPointerUp)
  }

  toggle(event) {
    event?.preventDefault()
    const active = this.element.classList.toggle("is-selecting")
    if (this.hasToggleTarget) {
      this.toggleTarget.textContent = active ? this.doneLabelValue : this.selectLabelValue
    }
    if (!active) this.clearSelection()
    this.update()
  }

  update() {
    const checked = this.checkedIds()
    const count   = checked.length
    if (this.hasCountTarget) {
      this.countTarget.textContent = this.selectedTemplateValue.replace("{count}", count)
    }
    if (this.hasBarTarget) this.barTarget.hidden = count === 0
  }

  cancel(event) {
    event?.preventDefault()
    this.clearSelection()
    this.element.classList.remove("is-selecting")
    if (this.hasToggleTarget) this.toggleTarget.textContent = this.selectLabelValue
    this.update()
  }

  submit(event) {
    event?.preventDefault()
    const ids = this.checkedIds()
    if (ids.length === 0) return
    const msg = this.confirmTemplateValue.replace("{count}", ids.length)
    if (!window.confirm(msg)) return

    const form = document.createElement("form")
    form.method = "post"
    form.action = this.actionUrlValue
    form.style.display = "none"

    const method = document.createElement("input")
    method.type  = "hidden"
    method.name  = "_method"
    method.value = "delete"
    form.appendChild(method)

    const tokenMeta = document.querySelector("meta[name='csrf-token']")
    if (tokenMeta) {
      const token = document.createElement("input")
      token.type  = "hidden"
      token.name  = "authenticity_token"
      token.value = tokenMeta.content
      form.appendChild(token)
    }

    ids.forEach(id => {
      const input = document.createElement("input")
      input.type  = "hidden"
      input.name  = "ids[]"
      input.value = id
      form.appendChild(input)
    })

    document.body.appendChild(form)
    form.submit()
  }

  // Drag-to-multi-select. In select mode, pressing on a card and dragging
  // across others toggles each card the cursor passes over. The drag mode
  // (select vs. deselect) is locked to the OPPOSITE of the first card's
  // initial checked state, so dragging from an unchecked card selects a
  // range and dragging from a checked one deselects it.
  onPointerDown(event) {
    if (!this.element.classList.contains("is-selecting")) return
    if (event.pointerType === "mouse" && event.button !== 0) return
    // Native UI inside cards (edit / results / delete links, the checkbox
    // label itself) keeps its own click behaviour.
    if (event.target.closest("a, button, input, label")) return

    const card = event.target.closest(".dashboard-card")
    if (!card) return
    const cb = this._checkboxFor(card)
    if (!cb) return

    this._dragMode  = cb.checked ? "deselect" : "select"
    cb.checked      = this._dragMode === "select"
    this._lastCard  = card
    this.update()

    document.addEventListener("pointermove", this._onPointerMove)
    document.addEventListener("pointerup",   this._onPointerUp, { once: true })
    event.preventDefault()
  }

  onPointerMove(event) {
    if (!this._dragMode) return
    const el   = document.elementFromPoint(event.clientX, event.clientY)
    const card = el?.closest(".dashboard-card")
    if (!card || card === this._lastCard) return
    const cb = this._checkboxFor(card)
    if (!cb) return
    const want = this._dragMode === "select"
    if (cb.checked !== want) {
      cb.checked = want
      this.update()
    }
    this._lastCard = card
  }

  onPointerUp() {
    this._dragMode = null
    this._lastCard = null
    document.removeEventListener("pointermove", this._onPointerMove)
  }

  _checkboxFor(card) {
    return card.querySelector('[data-bulk-select-target~="checkbox"]')
  }

  checkedIds() {
    return this.checkboxTargets
      .filter(cb => cb.checked)
      .map(cb => cb.dataset.surveyId)
      .filter(Boolean)
  }

  clearSelection() {
    this.checkboxTargets.forEach(cb => { cb.checked = false })
  }
}
