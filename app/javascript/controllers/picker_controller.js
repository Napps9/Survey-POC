import { Controller } from "@hotwired/stimulus"
import { haptic } from "lib/haptics"

// Tap-to-select for pick-list rows, choice-grid cards, etc.
//
// Modes:
//   "single" — only one item selected at a time
//   "multi"  — toggle each item independently
//
// Items must be marked data-picker-target="item".
// Clicks on contenteditable text or buttons inside the item are ignored,
// so inline editing and per-row remove buttons keep working.
export default class extends Controller {
  static targets = ["item"]
  static values  = { mode: { type: String, default: "single" } }

  pick(event) {
    if (event.target.isContentEditable) return
    if (event.target.closest("button")) return
    event.stopPropagation() // don't also select/apply the type underneath
    const item = event.currentTarget
    if (this.modeValue === "multi") {
      this.setSelected(item, item.dataset.selected !== "true")
    } else {
      this.itemTargets.forEach((el) => this.setSelected(el, el === item))
    }
    haptic()
    this.dispatch("pick", { detail: { mode: this.modeValue } })
  }

  setSelected(item, on) {
    item.dataset.selected = on ? "true" : "false"
  }
}
