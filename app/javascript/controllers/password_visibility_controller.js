import { Controller } from "@hotwired/stimulus"

// Toggles a password input between hidden and visible.
// Usage:
//   <div data-controller="password-visibility"
//        data-password-visibility-show-label-value="Show"
//        data-password-visibility-hide-label-value="Hide"
//        data-password-visibility-show-aria-value="Show password"
//        data-password-visibility-hide-aria-value="Hide password">
//     <input type="password" data-password-visibility-target="input">
//     <button type="button" data-action="password-visibility#toggle"
//             data-password-visibility-target="button">Show</button>
//   </div>
//
// All four labels come in as values rather than living here, because this
// controller now runs on the respondent player, which is drawn in 26
// languages. The English defaults are what the creator pages used to get by
// accident — hideLabel was never passed, so a French creator pressed
// "Afficher" and got "Hide" — and are kept only so a caller that forgets one
// degrades to a word rather than to nothing.
export default class extends Controller {
  static targets = ["input", "button"]
  static values  = {
    showLabel: { type: String, default: "Show" },
    hideLabel: { type: String, default: "Hide" },
    showAria:  { type: String, default: "Show password" },
    hideAria:  { type: String, default: "Hide password" }
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
    this.buttonTarget.textContent = shown ? this.hideLabelValue : this.showLabelValue
    this.buttonTarget.setAttribute("aria-pressed", shown ? "true" : "false")
    this.buttonTarget.setAttribute("aria-label", shown ? this.hideAriaValue : this.showAriaValue)
  }
}
