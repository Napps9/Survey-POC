import { Controller } from "@hotwired/stimulus"

// Generic tap-to-select controller for select_one, select_many, yes_no,
// matrix rows, rating stars, and the NPS numeric strip.
//
// Modes:
//   "single" — only one item selected at a time
//   "multi"  — toggle each item independently
//   "stars"  — like single, but visually fills 0..index inclusive
//
// Items must be marked with data-picker-target="item".
// Clicks inside contenteditable text are ignored so inline editing works.
export default class extends Controller {
  static targets = ["item"]
  static values  = { mode: { type: String, default: "single" } }

  pick(event) {
    if (event.target.isContentEditable) return
    const item = event.currentTarget
    const idx  = this.itemTargets.indexOf(item)
    if (idx === -1) return

    if (this.modeValue === "multi") {
      this.toggle(item)
    } else if (this.modeValue === "stars") {
      this.itemTargets.forEach((el, i) => this.setSelected(el, i <= idx))
    } else {
      this.itemTargets.forEach((el) => this.setSelected(el, el === item))
    }
  }

  toggle(item) {
    this.setSelected(item, item.dataset.selected !== "true")
  }

  setSelected(item, on) {
    item.dataset.selected = on ? "true" : "false"
  }
}
