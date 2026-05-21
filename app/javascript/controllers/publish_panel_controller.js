import { Controller } from "@hotwired/stimulus"

// Toggles the right-hand column between the answer-type picker, the design
// panel (colours / background / logo) and the publish & share panel. The
// bottom-bar CTAs open the design and publish views; the back button inside
// each returns to the answer-type view.
export default class extends Controller {
  static targets = ["typeView", "publishView", "designView"]

  open() { this._show("publishView") }
  openDesign() { this._show("designView") }
  close() { this._show("typeView") }

  _show(which) {
    this.typeViewTarget.classList.toggle("hidden", which !== "typeView")
    this.publishViewTarget.classList.toggle("hidden", which !== "publishView")
    this.designViewTarget.classList.toggle("hidden", which !== "designView")
  }
}
