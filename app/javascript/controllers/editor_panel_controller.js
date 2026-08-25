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

  // `event` is present only when this was fired by a data-action. On a phone
  // a card tap must edit the card IN PLACE — popping the panel over it is the
  // desktop behaviour and would bury the thing just tapped under a sheet. The
  // dock and the chips still open it, because they call open() with no event
  // (or from their own actions), and every desktop width is unaffected.
  open(event) {
    if (event?.type === "type-panel:cardSelected" && this._isPhone()) return
    if (this.hasGridTarget) this.gridTarget.classList.add("is-panel-open")
  }

  // The one width the studio calls a phone — kept identical to
  // mobile_studio_controller's QUERY and the CSS blocks.
  _isPhone() {
    return window.matchMedia("(max-width: 767px)").matches
  }

  close() {
    if (this.hasGridTarget) this.gridTarget.classList.remove("is-panel-open")
  }
}
