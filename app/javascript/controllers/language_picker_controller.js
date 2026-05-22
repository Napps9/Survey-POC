import { Controller } from "@hotwired/stimulus"

// Verto creation: pick the languages to build in, plus which is primary (the
// generation source). Keeps the primary language always selected and shows a
// running count.
export default class extends Controller {
  static targets = ["option", "primary", "summary"]

  connect() {
    this.syncPrimary()
    this.updateSummary()
  }

  // Ensure the chosen primary language is always checked.
  syncPrimary() {
    const primary = this.primaryTarget.value
    this.optionTargets.forEach(cb => {
      if (cb.value === primary) cb.checked = true
    })
    this.updateSummary()
  }

  toggle(event) {
    // Don't allow unchecking the primary language.
    const cb = event.target
    if (cb.value === this.primaryTarget.value && !cb.checked) cb.checked = true
    this.updateSummary()
  }

  updateSummary() {
    if (!this.hasSummaryTarget) return
    const n = this.optionTargets.filter(cb => cb.checked).length
    this.summaryTarget.textContent = n === 1 ? "1 language selected" : `${n} languages selected`
  }
}
