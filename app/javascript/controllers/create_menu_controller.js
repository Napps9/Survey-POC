import { Controller } from "@hotwired/stimulus"

// The dashboard's "+ Create" popup: pick what to create — Impact Measurement
// (the AI wizard), Quiz (same wizard, quiz pre-set), Form (the existing
// Google-Form import / start-from-scratch flow, one level deeper), or a
// Template. Reopens itself straight into the Form panel after a server
// round-trip (an import error, or landing back here post-Google-connect)
// via the reopen value set from the view.
export default class extends Controller {
  static targets = ["modal", "chooser", "formPanel", "urlInput"]
  static values = { reopen: Boolean }

  connect() {
    if (this.reopenValue) this.openForm()
  }

  open() {
    this._show()
    this._swap(false)
  }

  // The Form tile — and the reopen-after-error path — land here.
  openForm() {
    this._show()
    this._swap(true)
    if (this.hasUrlInputTarget) this.urlInputTarget.focus()
  }

  back() {
    this._swap(false)
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.style.overflow = ""
  }

  closeOnEsc() {
    if (this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) this.close()
  }

  _show() {
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
  }

  _swap(toForm) {
    if (this.hasChooserTarget)   this.chooserTarget.classList.toggle("hidden", toForm)
    if (this.hasFormPanelTarget) this.formPanelTarget.classList.toggle("hidden", !toForm)
  }
}
