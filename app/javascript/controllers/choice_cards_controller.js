import { Controller } from "@hotwired/stimulus"

// Radio "choice cards": highlights the selected card and (optionally) updates a
// submit button's formAction + label from the chosen radio's data attributes.
// CSP-friendly replacement for the inline onchange that restyled siblings and
// switched the form target.
//
//   <div data-controller="choice-cards"
//        data-choice-cards-selected-border-value="#FF1E6F"
//        data-choice-cards-selected-bg-value="rgba(255,30,111,0.04)">
//     <label class="populate-choice" data-choice-cards-target="choice">
//       <input type="radio" data-action="change->choice-cards#select"
//              data-formaction="/path" data-label="Go →">
//     </label>
//     <button data-choice-cards-target="submit">…</button>   (optional)
//   </div>
export default class extends Controller {
  static targets = ["choice", "submit"]
  static values = {
    selectedBorder: String,
    selectedBg: String,
    unselectedBorder: { type: String, default: "rgba(0,0,0,0.08)" },
    unselectedBg: { type: String, default: "#fafbfc" }
  }

  connect() { this.refresh() }

  select(event) {
    this.refresh()
    this.updateSubmit(event.target)
  }

  refresh() {
    this.choiceTargets.forEach((label) => {
      const radio = label.querySelector("input[type=radio]")
      const on = !!(radio && radio.checked)
      label.style.borderColor = on ? this.selectedBorderValue : this.unselectedBorderValue
      label.style.background = on ? this.selectedBgValue : this.unselectedBgValue
      if (on) this.updateSubmit(radio)
    })
  }

  updateSubmit(radio) {
    if (!this.hasSubmitTarget || !radio) return
    const action = radio.dataset.formaction
    const label = radio.dataset.label
    if (action) this.submitTarget.formAction = action
    if (label != null && label !== "") {
      if (this.submitTarget.tagName === "BUTTON") this.submitTarget.textContent = label
      else this.submitTarget.value = label
    }
  }
}
