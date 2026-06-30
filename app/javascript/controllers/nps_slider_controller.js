import { Controller } from "@hotwired/stimulus"

// Vertical 5-step slider on the right panel. The pill outline + interior
// clipping come from CSS on .nps-control; the controller positions
// .nps-thumb and sets --nps-fill (0..1) which CSS uses to grow the
// .nps-track-fill div from the bottom. On every step landing it dispatches
// `nps:valueChanged` with the 1-indexed value for the left-panel
// lottie-player to swap the matching Lottie animation.
export default class extends Controller {
  static targets = ["label"]
  static values  = {
    steps: { type: Number, default: 5 },
    index: { type: Number, default: -1 },
    axis:  { type: String, default: "vertical" }
  }

  connect() {
    this._onMove = (e) => this._drag(e)
    this._onUp   = () => this._end()

    this.control = this.element.querySelector(".nps-control")
    this.thumb   = this.control && this.control.querySelector(".nps-thumb")

    if (this.indexValue < 0) this.indexValue = 0
    this._render(this.indexValue, { emit: true })
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
    const prev = this.indexValue
    this.indexValue = Math.max(0, Math.min(n - 1, this.indexValue + (up ? 1 : -1)))
    this._render(this.indexValue, { emit: this.indexValue !== prev })
  }

  _drag(event) { if (this.dragging) this._fromEvent(event) }

  _end() {
    this.dragging = false
    window.removeEventListener("pointermove", this._onMove)
    this._render(this.indexValue, { emit: false }) // settle to the stop
  }

  _fromEvent(event) {
    const rect = (this.control || this.element).getBoundingClientRect()
    const ratio = this.axisValue === "horizontal"
      ? (event.clientX - rect.left) / rect.width
      : (rect.bottom - event.clientY) / rect.height
    const r = Math.max(0, Math.min(1, ratio))
    const n = Math.max(2, this.stepsValue)
    const idx = Math.round(r * (n - 1))
    const changed = idx !== this.indexValue
    this.indexValue = idx
    this._render(idx, { emit: changed })
  }

  _render(idx, { emit }) {
    const ratio = this._ratioFor(idx)
    this._positionThumb(ratio)
    if (this.control) this.control.style.setProperty("--nps-fill", ratio.toFixed(3))

    const value = idx + 1 // 1-indexed for display + events
    this.element.dataset.npsValue = value
    const lbl  = this.labelTargets[idx]
    const text = lbl ? lbl.textContent.trim() : `${value}`
    this.labelTargets.forEach((l, i) => l.classList.toggle("is-active", i === idx))
    this.element.setAttribute("aria-valuenow", value)
    this.element.setAttribute("aria-valuetext", text)

    if (emit) {
      document.dispatchEvent(new CustomEvent("nps:valueChanged", {
        detail: { value, index: idx, text }
      }))
    }
  }

  _ratioFor(idx) {
    return this.stepsValue > 1 ? idx / (this.stepsValue - 1) : 0
  }

  // Thumb is inset by half a step on each end so its position matches the
  // CENTRES of the labels (which take an equal 1/N share of the column).
  // For 5 steps the inset is 10% — thumb travels 10%..90% instead of 0..100%.
  _positionThumb(ratio) {
    if (!this.thumb) return
    const inset = 100 / (2 * Math.max(2, this.stepsValue))
    const travel = 100 - 2 * inset
    if (this.axisValue === "horizontal") {
      this.thumb.style.left = `${inset + ratio * travel}%`
      this.thumb.style.top  = "50%"
    } else {
      this.thumb.style.left = "50%"
      this.thumb.style.top  = `${inset + (1 - ratio) * travel}%`
    }
  }
}
