import { Controller } from "@hotwired/stimulus"

// The account menu in the top bar of /you.
//
// Nothing in it is reachable ONLY through this controller: every item is a
// link or a form, and the settings page carries the same actions in full. So
// with the controller dead the button does nothing and nothing is lost.
//
// Modelled on wallet_pill_controller: the document listeners are attached in
// connect and removed in disconnect, because Turbo keeps the document across
// visits and a listener that outlives its element closes a menu that is no
// longer there — or, worse, one that belongs to the next page.
export default class extends Controller {
  static targets = ["popover"]

  connect() {
    this.boundKeydown = this.onKeydown.bind(this)
    this.boundDocClick = this.onDocClick.bind(this)
    document.addEventListener("keydown", this.boundKeydown)
    document.addEventListener("click", this.boundDocClick)
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundKeydown)
    document.removeEventListener("click", this.boundDocClick)
  }

  toggle() {
    this.open ? this.close() : this.show()
  }

  show() {
    if (!this.hasPopoverTarget) return
    this.popoverTarget.hidden = false
    this.button?.setAttribute("aria-expanded", "true")
  }

  close() {
    if (!this.hasPopoverTarget) return
    this.popoverTarget.hidden = true
    this.button?.setAttribute("aria-expanded", "false")
  }

  get open() {
    return this.hasPopoverTarget && !this.popoverTarget.hidden
  }

  get button() {
    return this.element.querySelector("[aria-haspopup]")
  }

  onKeydown(event) {
    if (event.key === "Escape") this.close()
  }

  // A click anywhere outside the wrapper — the button and the panel are both
  // inside it, so travelling between them never counts as leaving.
  onDocClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }
}
