import { Controller } from "@hotwired/stimulus"

// The themed asset on the RIGHT is the slider. Dragging along its axis
// (vertical: up = best, horizontal: right = best) moves a visible handle
// (.nps-thumb), fills the asset (--nps-fill), snaps to the nearest labelled
// stop, records the index, and drives the reactive asset on the LEFT.
export default class extends Controller {
  static targets = ["label", "tooltip"]
  static values  = { steps: Number, index: { type: Number, default: -1 }, axis: { type: String, default: "vertical" } }

  connect() {
    this._onMove = (e) => this._drag(e)
    this._onUp   = () => this._end()
    this.inset   = 26

    this.control = this.element.querySelector(".nps-control")
    this.svg     = this.control && this.control.querySelector(".nps-svg")
    this.thumb   = this.control && this.control.querySelector(".nps-thumb")
    this.vb      = this._viewBox(this.svg)

    const card = this.element.closest(".split-card")
    this.reaction       = card ? card.querySelector(".split-left .nps-visual") : null
    this.reactionStates = this.reaction ? Array.from(this.reaction.querySelectorAll(".nps-state")) : []

    if (this.indexValue < 0) this.indexValue = Math.floor((this.stepsValue - 1) / 2)
    this._render(this.indexValue, this._ratioFor(this.indexValue))
  }

  start(event) {
    if (event.target.isContentEditable) return
    event.preventDefault()
    this.element.focus()
    this.dragging = true
    this._fromEvent(event)
    window.addEventListener("pointermove", this._onMove)
    window.addEventListener("pointerup",   this._onUp, { once: true })
  }

  key(event) {
    const up   = ["ArrowUp", "ArrowRight"].includes(event.key)
    const down = ["ArrowDown", "ArrowLeft"].includes(event.key)
    if (!up && !down) return
    event.preventDefault()
    const n = Math.max(2, this.stepsValue)
    this.indexValue = Math.max(0, Math.min(n - 1, this.indexValue + (up ? 1 : -1)))
    this._render(this.indexValue, this._ratioFor(this.indexValue))
  }

  _drag(event) { if (this.dragging) this._fromEvent(event) }

  _end() {
    this.dragging = false
    window.removeEventListener("pointermove", this._onMove)
    this._render(this.indexValue, this._ratioFor(this.indexValue)) // settle to the stop
  }

  _fromEvent(event) {
    const rect = (this.control || this.element).getBoundingClientRect()
    const ratio = this.axisValue === "horizontal"
      ? (event.clientX - rect.left) / rect.width
      : (rect.bottom - event.clientY) / rect.height
    const r = Math.max(0, Math.min(1, ratio))
    const n = Math.max(2, this.stepsValue)
    this.indexValue = Math.round(r * (n - 1))
    this._render(this.indexValue, r) // fill/handle follow the pointer while dragging
  }

  _ratioFor(idx) {
    return this.stepsValue > 1 ? idx / (this.stepsValue - 1) : 0
  }

  _render(idx, ratio) {
    this._drive(this.control, [], ratio)
    this._positionThumb(ratio)
    this._drive(this.reaction, this.reactionStates, ratio)

    this.element.dataset.npsValue = idx
    const lbl = this.labelTargets[idx]
    const text = lbl ? lbl.textContent.trim() : `${idx}`
    this.labelTargets.forEach((l, i) => l.classList.toggle("is-active", i === idx))
    if (this.hasTooltipTarget) this.tooltipTarget.textContent = text
    this.element.setAttribute("aria-valuenow", idx)
    this.element.setAttribute("aria-valuetext", text)
  }

  _positionThumb(ratio) {
    if (!this.thumb) return
    const [minx, miny, w, h] = this.vb
    let x, y
    if (this.axisValue === "horizontal") {
      y = miny + h / 2
      x = minx + this.inset + ratio * (w - 2 * this.inset)
    } else {
      x = minx + w / 2
      y = (miny + h - this.inset) - ratio * (h - 2 * this.inset)
    }
    this.thumb.style.transform = `translate(${x}px, ${y}px)`
  }

  // fill (--nps-fill, scaled per data-axis in CSS) + sentiment hue, and (states
  // mode) the active expression mapped from the ratio.
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

  _viewBox(svg) {
    const raw = svg && svg.getAttribute("viewBox")
    const p = raw ? raw.split(/[\s,]+/).map(Number) : [0, 0, 200, 200]
    return p.length === 4 && p.every(Number.isFinite) ? p : [0, 0, 200, 200]
  }
}
