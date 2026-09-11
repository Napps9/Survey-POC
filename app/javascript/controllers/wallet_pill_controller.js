import { Controller } from "@hotwired/stimulus"

// The hover breakdown behind the wallet pill.
//
// Nothing here is load-bearing: the pill is a link, so with this controller
// dead — or on a device with no pointer at all — tapping it still opens the
// wallet, which is where every row in the popover also lives.
//
// Closing is delayed by a beat because the popover is a sibling of the pill,
// not a child of it: without the grace period a pointer crossing the pill's own
// rounded corner on its way in can leave and re-enter, and the panel flickers.
// The listeners are on the controller element, which wraps both, so travelling
// from the pill into the popover never leaves it in the first place.
const CLOSE_DELAY = 120

export default class extends Controller {
  static targets = ["popover"]

  connect() {
    this.boundKeydown = this.onKeydown.bind(this)
    this.boundDocPointer = this.onDocPointer.bind(this)
    document.addEventListener("keydown", this.boundKeydown)
    // Touch has no mouseleave. A tap elsewhere is the only "I'm done with it"
    // signal a phone gives, and one arrives here on any device.
    document.addEventListener("click", this.boundDocPointer)
  }

  disconnect() {
    this.cancelClose()
    document.removeEventListener("keydown", this.boundKeydown)
    document.removeEventListener("click", this.boundDocPointer)
  }

  open() {
    this.cancelClose()
    if (this.hasPopoverTarget) this.popoverTarget.hidden = false
  }

  close() {
    this.cancelClose()
    this.closeTimer = setTimeout(() => this.closeNow(), CLOSE_DELAY)
  }

  closeNow() {
    if (this.hasPopoverTarget) this.popoverTarget.hidden = true
  }

  cancelClose() {
    if (this.closeTimer) clearTimeout(this.closeTimer)
    this.closeTimer = null
  }

  onKeydown(event) {
    if (event.key === "Escape") this.closeNow()
  }

  onDocPointer(event) {
    if (!this.element.contains(event.target)) this.closeNow()
  }
}
