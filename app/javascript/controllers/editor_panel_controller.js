import { Controller } from "@hotwired/stimulus"

// Collapses the right-hand editor panel until it's needed. The editor opens
// with the panel closed and the cards centred like the player; selecting a
// card (or opening Publish / Design) slides the panel in from the edge, and
// its ✕ tab collapses it again. State is .is-panel-open on the editor grid.
export default class extends Controller {
  static targets = ["grid"]

  open() {
    if (this.hasGridTarget) this.gridTarget.classList.add("is-panel-open")
  }

  close() {
    if (this.hasGridTarget) this.gridTarget.classList.remove("is-panel-open")
  }
}
