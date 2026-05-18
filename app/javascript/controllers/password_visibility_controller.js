import { Controller } from "@hotwired/stimulus"

// Toggles a password input between hidden and visible.
// Usage:
//   <div data-controller="password-visibility">
//     <input type="password" data-password-visibility-target="input">
//     <button type="button" data-action="password-visibility#toggle"
//             data-password-visibility-target="button">Show</button>
//   </div>
export default class extends Controller {
  static targets = ["input", "button"]
  static values  = {
    showLabel: { type: String, default: "Show" },
    hideLabel: { type: String, default: "Hide" }
  }

  connect() { this.sync() }

  toggle(event) {
    event?.preventDefault()
    const shown = this.inputTarget.type === "text"
    this.inputTargets.forEach(el => { el.type = shown ? "password" : "text" })
    this.sync()
  }

  sync() {
    if (!this.hasButtonTarget) return
    const shown = this.inputTarget.type === "text"
    this.buttonTarget.textContent     = shown ? this.hideLabelValue : this.showLabelValue
    this.buttonTarget.setAttribute("aria-pressed", shown ? "true" : "false")
    this.buttonTarget.setAttribute("aria-label",
      shown ? "Hide password" : "Show password")
  }
}
