import { Controller } from "@hotwired/stimulus"

// Textarea with live character counter. Counter turns hot-pink past max.
export default class extends Controller {
  static targets = ["input", "counter"]
  static values  = { max: { type: Number, default: 200 } }

  connect() { this.update() }

  update() {
    const len = (this.inputTarget.value || "").length
    if (this.hasCounterTarget) {
      this.counterTarget.textContent = `${len}/${this.maxValue} Characters`
      this.counterTarget.classList.toggle("text-hot-pink", len > this.maxValue)
      this.counterTarget.classList.toggle("font-medium",   len > this.maxValue)
    }
  }
}
