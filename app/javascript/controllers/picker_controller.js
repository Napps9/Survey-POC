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
//
// Accessibility (P2-4): outside the editor each item carries role=radio or
// role=checkbox and tabindex=0, so it is reachable by keyboard. This controller
// owns the two things that has to come with: activating on Enter/Space, and
// keeping aria-checked in step with data-selected — a radio a screen reader
// can focus but never hear the state of is barely better than none.
export default class extends Controller {
  static targets = ["item"]
  static values  = { mode: { type: String, default: "single" } }

  // Enter and Space are what a keyboard user presses on a radio or checkbox.
  // Space is also page-scroll, so it must be prevented once it's been handled.
  pickOnKey(event) {
    if (event.key !== "Enter" && event.key !== " " && event.key !== "Spacebar") return
    if (event.target.isContentEditable) return
    event.preventDefault()
    this.pick(event)
  }

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
    // Only where the role was actually applied — in the editor these are plain
    // list items holding contenteditable text, and a stray aria-checked there
    // would announce edit fields as form controls.
    if (item.hasAttribute("role")) item.setAttribute("aria-checked", on ? "true" : "false")
  }
}
