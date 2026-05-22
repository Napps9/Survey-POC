import { Controller } from "@hotwired/stimulus"

// Toggles the language popover and closes it on outside-click / Escape.
export default class extends Controller {
  static targets = ["popover"]

  connect() {
    this.boundDocClick = this.onDocClick.bind(this)
    this.boundKeydown = this.onKeydown.bind(this)
    document.addEventListener("click", this.boundDocClick)
    document.addEventListener("keydown", this.boundKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.boundDocClick)
    document.removeEventListener("keydown", this.boundKeydown)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.hasPopoverTarget) this.popoverTarget.hidden = !this.popoverTarget.hidden
  }

  close() {
    if (this.hasPopoverTarget) this.popoverTarget.hidden = true
  }

  onDocClick(event) {
    if (!this.hasPopoverTarget || this.popoverTarget.hidden) return
    if (!this.element.contains(event.target)) this.close()
  }

  onKeydown(event) {
    if (event.key === "Escape") this.close()
  }
}
