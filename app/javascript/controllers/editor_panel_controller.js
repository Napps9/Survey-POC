import { Controller } from "@hotwired/stimulus"

// Collapses the right-hand editor panel until it's needed. The editor opens
// with the panel closed and the cards centred like the player; selecting a
// card (or opening Publish / Design) slides the panel in from the edge, and
// its ✕ tab collapses it again. State is .is-panel-open on the editor grid.
export default class extends Controller {
  static targets = ["grid"]

  connect() {
    // A quiz/logic/tokenisation toggle reloads the page with ?tab=<feature>
    // (echoed by update_settings); reopen the column so publish-panel's view
    // switch is actually visible. publish-panel cleans the param up a frame
    // later, after every controller has read it.
    if (new URLSearchParams(window.location.search).get("tab")) this.open()
  }

  open() {
    if (this.hasGridTarget) this.gridTarget.classList.add("is-panel-open")
  }

  close() {
    if (this.hasGridTarget) this.gridTarget.classList.remove("is-panel-open")
  }
}
