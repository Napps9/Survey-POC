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
  // `max` is the multi-select tick ceiling (Survey#max_choices, 0 = no limit).
  // Read only in multi mode: single-select already picks exactly one.
  static values  = { mode: { type: String, default: "single" }, max: { type: Number, default: 0 } }

  // A card restored from saved progress arrives with its selections already in
  // the DOM, so the dimming has to be computed rather than waiting for a tap.
  connect() {
    this.syncCap()
  }

  // The editor rewrites data-picker-max-value when a creator moves the cap, and
  // Stimulus observes that mutation asynchronously — so this, not a call at the
  // point of the write, is what makes the preview follow.
  maxValueChanged() {
    this.syncCap()
  }

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
      const on = item.dataset.selected !== "true"
      // At the ceiling the extra tap does nothing at all — no selection, no
      // haptic, no event. Unticking is always allowed, which is what makes the
      // cap navigable rather than a dead end: the way past it is to give one up.
      if (on && this._atCap()) return
      this.setSelected(item, on)
    } else {
      this.itemTargets.forEach((el) => this.setSelected(el, el === item))
    }
    this.syncCap()
    haptic()
    this.dispatch("pick", { detail: { mode: this.modeValue } })
  }

  // Mark the list as full so CSS can dim what can no longer be picked. Public
  // because player_controller#_applyValue writes data-selected straight onto
  // the items when it restores an answer, bypassing setSelected entirely.
  syncCap() {
    if (this.modeValue !== "multi") return
    // No cap (or the cap just lifted): leave nothing behind for the CSS to dim.
    if (this.maxValue < 2) {
      delete this.element.dataset.atCap
      this.itemTargets.forEach((el) => el.removeAttribute("aria-disabled"))
      return
    }
    const full = this._atCap()
    this.element.dataset.atCap = full ? "true" : "false"
    // Not purely visual: an option a respondent cannot choose has to say so to
    // a screen reader too. Selected items stay enabled — unticking is the way
    // back under the cap.
    this.itemTargets.forEach((el) => {
      const spare = !full || el.dataset.selected === "true"
      spare ? el.removeAttribute("aria-disabled") : el.setAttribute("aria-disabled", "true")
    })
  }

  _atCap() {
    if (this.maxValue < 2) return false
    return this.itemTargets.filter((el) => el.dataset.selected === "true").length >= this.maxValue
  }

  setSelected(item, on) {
    item.dataset.selected = on ? "true" : "false"
    // Only where the role was actually applied — in the editor these are plain
    // list items holding contenteditable text, and a stray aria-checked there
    // would announce edit fields as form controls.
    if (item.hasAttribute("role")) item.setAttribute("aria-checked", on ? "true" : "false")
  }
}
