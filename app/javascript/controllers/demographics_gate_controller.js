import { Controller } from "@hotwired/stimulus"

const ACK_KEY = "verto_demographics_ack"

// One-time explainer shown the first time a creator hits "Generate": every
// Verto ends with the same three demographic questions, and here's why.
// Ordered before generating#show on the form's submit, so it can hold the
// submit until acknowledged. The PDF-import path and returning creators pass
// straight through.
export default class extends Controller {
  static targets = ["modal"]

  check(e) {
    if (e.submitter?.hasAttribute("data-generating-import")) return
    if (this._acked()) return
    // If the brief is incomplete, let the event fall through to
    // generating#show (next in the submit action chain) so its own
    // shake-the-CTA feedback fires instead of this modal — a first-time
    // creator should see why the click "didn't work" before an unrelated
    // one-time explainer.
    if (this._requiredFieldsMissing()) return
    e.preventDefault()
    e.stopImmediatePropagation()
    this._submitter = e.submitter
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
  }

  _requiredFieldsMissing() {
    const generatingEl = this.element.closest('[data-controller~="generating"]')
    const generating = generatingEl &&
      this.application.getControllerForElementAndIdentifier(generatingEl, "generating")
    return generating ? generating.requiredFieldsMissing(this.element) : false
  }

  // "Got it" — remember the acknowledgement and let the generation proceed.
  confirm() {
    try { localStorage.setItem(ACK_KEY, "1") } catch (_) { /* private mode */ }
    this._close()
    this.element.requestSubmit(this._submitter || undefined)
  }

  dismiss() { this._close() }

  closeOnEsc() {
    if (!this.modalTarget.classList.contains("hidden")) this._close()
  }

  _close() {
    this.modalTarget.classList.add("hidden")
    document.body.style.overflow = ""
  }

  _acked() {
    try { return localStorage.getItem(ACK_KEY) === "1" } catch (_) { return false }
  }
}
