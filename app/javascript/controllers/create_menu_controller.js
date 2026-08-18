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

  // Every entry point below is a no-op without the modal in the DOM. A managed
  // account (Organisation#verto_creation_enabled false) doesn't render it, and
  // ?open_import=1 would otherwise arrive here and dereference a missing target.
  // The view already forces reopen false in that case; this is the half that
  // survives someone removing the modal again later.
  _hasModal() {
    return this.hasModalTarget
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
    if (!this._hasModal()) return
    this.modalTarget.classList.add("hidden")
    document.body.style.overflow = ""
  }

  closeOnEsc() {
    if (this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) this.close()
  }

  _show() {
    if (!this._hasModal()) return
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
  }

  _swap(toForm) {
    if (this.hasChooserTarget)   this.chooserTarget.classList.toggle("hidden", toForm)
    if (this.hasFormPanelTarget) this.formPanelTarget.classList.toggle("hidden", !toForm)
  }
}
