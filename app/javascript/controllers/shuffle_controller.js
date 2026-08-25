import { Controller } from "@hotwired/stimulus"

// The Shuffle split pill's direction panel. Shuffle itself is a plain form
// submit and stays that way — this only opens and closes the optional
// "direction prompt" (what the creator wants out of the content and imagery)
// that rides along in the same form, so a creator who doesn't care never has
// an extra step and the button behaves exactly as it did before.
//
// The textarea is inside the form whether the panel is open or shut, so BOTH
// submit buttons carry the direction; the panel is presentation only.
export default class extends Controller {
  static targets = ["panel", "toggle", "input"]

  connect() {
    // Click-outside closes. Bound on the document because the panel floats
    // over the card feed, so "outside" is most of the screen.
    this._outside = (e) => { if (!this.element.contains(e.target)) this.close() }
    document.addEventListener("click", this._outside)
  }

  disconnect() {
    document.removeEventListener("click", this._outside)
  }

  toggle(event) {
    event?.preventDefault()
    this.panelTarget.hidden ? this.open() : this.close()
  }

  open() {
    this.panelTarget.hidden = false
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", "true")
    if (this.hasInputTarget) this.inputTarget.focus()
  }

  close() {
    if (this.panelTarget.hidden) return
    this.panelTarget.hidden = true
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", "false")
  }

  // Empties the box. Nothing is stored, so this is the whole of clearing — it
  // used to only empty the textarea while a saved steer went on applying,
  // which meant a button labelled Clear that cleared nothing you could see.
  clear(event) {
    event?.preventDefault()
    if (!this.hasInputTarget) return
    this.inputTarget.value = ""
    this.inputTarget.focus()
  }
}
