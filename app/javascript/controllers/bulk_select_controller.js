import { Controller } from "@hotwired/stimulus"

// Enables a "Select" mode on a section of dashboard cards. Toggling the mode
// reveals a checkbox on each card, and the action bar appears as soon as
// anything is selected. Submitting builds an ad-hoc form that DELETEs to
// `actionUrlValue` with an `ids[]` payload — the controller action archives
// or hard-destroys based on which URL was wired up.
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
