import { Controller } from "@hotwired/stimulus"

// Warns the editor that this Verto is LIVE and that editing affects data
// quality. Shown as a modal on page load; the editor dismisses it to continue.
export default class extends Controller {
  connect() {
    this._escListener = (e) => { if (e.key === "Escape") this.dismiss() }
    document.addEventListener("keydown", this._escListener)
    this.element.classList.remove("hidden") // re-show on Turbo restore
  }

  disconnect() {
    document.removeEventListener("keydown", this._escListener)
  }

  dismiss() {
    this.element.classList.add("hidden")
    document.removeEventListener("keydown", this._escListener)
  }

  backdropClick(event) {
    if (event.target === this.element) this.dismiss()
  }
}
