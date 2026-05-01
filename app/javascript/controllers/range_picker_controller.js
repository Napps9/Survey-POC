import { Controller } from "@hotwired/stimulus"

// Pointer-drag thumb on a track. Supports horizontal or vertical orientation.
// Snaps to N steps; updates a label element to the current step's text.
export default class extends Controller {
  static targets = ["track", "thumb", "fill", "label", "step"]
  static values  = {
    steps:       Number,
    index:       { type: Number,  default: 0 },
    orientation: { type: String,  default: "horizontal" } // or "vertical"
  }

  connect() {
    this._onMove = this.onMove.bind(this)
    this._onUp   = this.onUp.bind(this)
    this.render()
  }

  start(event) {
    if (event.target.isContentEditable) return
    event.preventDefault()
    this.dragging = true
    this.updateFromEvent(event)
    window.addEventListener("pointermove", this._onMove)
    window.addEventListener("pointerup",   this._onUp, { once: true })
  }

  onMove(event) { if (this.dragging) this.updateFromEvent(event) }
  onUp() {
    this.dragging = false
    window.removeEventListener("pointermove", this._onMove)
  }

  updateFromEvent(event) {
    const rect  = this.trackTarget.getBoundingClientRect()
    const ratio = this.orientationValue === "vertical"
      ? Math.max(0, Math.min(1, (event.clientY - rect.top)  / rect.height))
      : Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width))
    const n   = Math.max(1, this.stepsValue)
    const idx = Math.round(ratio * (n - 1))
    if (idx !== this.indexValue) {
      this.indexValue = idx
      this.render()
    }
  }

  render() {
    const n = Math.max(1, this.stepsValue)
    const ratio = n === 1 ? 0.5 : this.indexValue / (n - 1)
    if (this.hasThumbTarget) {
      if (this.orientationValue === "vertical") {
        this.thumbTarget.style.top = `${ratio * 100}%`
      } else {
        this.thumbTarget.style.left = `${ratio * 100}%`
      }
    }
    if (this.hasFillTarget) {
      if (this.orientationValue === "vertical") {
        this.fillTarget.style.height = `${ratio * 100}%`
      } else {
        this.fillTarget.style.width = `${ratio * 100}%`
      }
    }
    if (this.hasLabelTarget && this.hasStepTarget) {
      const step = this.stepTargets[this.indexValue]
      this.labelTarget.textContent = step ? step.textContent.trim() : ""
    }
  }
}
