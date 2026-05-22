import { Controller } from "@hotwired/stimulus"

// The themed slider on the RIGHT (e.g. a thermometer) is the drag control.
// Dragging it vertically (top = best) sets the value, fills the control asset,
// AND drives the reactive asset on the LEFT (e.g. a sun face) so its expression
// and colour track the slider. Records the chosen index for answer capture.
export default class extends Controller {
  static targets = ["label", "tooltip"]
  static values  = { steps: Number, index: { type: Number, default: -1 } }

  connect() {
    this._onMove = (e) => this._drag(e)
    this._onUp   = () => this._end()

    // Right control asset (inside this controller) + left reactive asset.
    this.control       = this.element.querySelector(".nps-visual")
    this.controlStates = Array.from(this.element.querySelectorAll(".nps-state"))
    const card = this.element.closest(".split-card")
    this.reaction       = card ? card.querySelector(".split-left .nps-visual") : null
    this.reactionStates = this.reaction ? Array.from(this.reaction.querySelectorAll(".nps-state")) : []

    if (this.indexValue < 0) this.indexValue = Math.floor((this.stepsValue - 1) / 2)
    this._render(this.indexValue, this._ratioFor(this.indexValue))
  }

  start(event) {
    if (event.target.isContentEditable) return
    event.preventDefault()
    this.dragging = true
    this._fromEvent(event)
    window.addEventListener("pointermove", this._onMove)
    window.addEventListener("pointerup",   this._onUp, { once: true })
  }

  _drag(event) { if (this.dragging) this._fromEvent(event) }

  _end() {
    this.dragging = false
    window.removeEventListener("pointermove", this._onMove)
    this._render(this.indexValue, this._ratioFor(this.indexValue)) // settle to the stop
  }

  _fromEvent(event) {
    const rect  = (this.control || this.element).getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (rect.bottom - event.clientY) / rect.height))
    const n     = Math.max(2, this.stepsValue)
    const idx   = Math.round(ratio * (n - 1))
    this.indexValue = idx
    this._render(idx, ratio) // fill follows the pointer while dragging
  }

  _ratioFor(idx) {
    return this.stepsValue > 1 ? idx / (this.stepsValue - 1) : 0
  }

  _render(idx, ratio) {
    this._drive(this.control, this.controlStates, ratio)
    this._drive(this.reaction, this.reactionStates, ratio)
    this.element.dataset.npsValue = idx

    this.labelTargets.forEach((l, i) => l.classList.toggle("is-active", i === idx))
    if (this.hasTooltipTarget) {
      const lbl = this.labelTargets[idx]
      this.tooltipTarget.textContent = lbl ? lbl.textContent.trim() : `${idx}`
    }
  }

  // Drive one stage: continuous fill + sentiment hue, and (states mode) the
  // active expression mapped from the ratio onto however many states it has.
  _drive(stage, states, ratio) {
    if (!stage) return
    stage.style.setProperty("--nps-fill", ratio.toFixed(3))
    stage.style.setProperty("--nps-hue", (ratio * 120).toFixed(1))
    const n = states.length
    if (n) {
      const s = Math.max(0, Math.min(n - 1, Math.round(ratio * (n - 1))))
      states.forEach((g, i) => g.classList.toggle("is-active", i === s))
    }
  }
}
