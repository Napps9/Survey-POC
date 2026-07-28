import { Controller } from "@hotwired/stimulus"

// Collapses the right-hand editor panel until it's needed. The editor opens
// with the panel closed and the cards centred like the player; selecting a
// card (or opening Publish / Design) slides the panel in from the edge, and
// its ✕ tab collapses it again. State is .is-panel-open on the editor grid.
export default class extends Controller {
  static targets = ["grid"]

  connect() {
    // Settings forms reload the page with ?tab=<feature> or ?panel=publish
    // (echoed by update_settings and the publish action); reopen the column
    // so publish-panel's view switch is actually visible. publish-panel
    // cleans the params up a frame later, after every controller reads them.
    const params = new URLSearchParams(window.location.search)
    if (params.get("tab") || params.get("panel") === "publish") this.open()
  }

  open() {
    if (this.hasGridTarget) this.gridTarget.classList.add("is-panel-open")
  }

  close() {
    if (this.hasGridTarget) this.gridTarget.classList.remove("is-panel-open")
  }
}
