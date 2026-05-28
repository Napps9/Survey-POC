import { Controller } from "@hotwired/stimulus"

// Verto slider: horizontal track with N dots, draggable thumb, floating
// tooltip. Snaps to nearest step on release; tooltip text comes from the
// `label` target at the matching index.
export default class extends Controller {
  static targets = ["track", "thumb", "tooltip", "tooltipText", "dot", "label"]
  static values  = { steps: Number, index: { type: Number, default: 0 } }

  connect() {
    this._onMove = this.onMove.bind(this)
    this._onUp   = this.onUp.bind(this)
    this.indexValue = Math.floor((this.stepsValue - 1) / 2)
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
    this.dispatch("settle", { detail: { index: this.indexValue } })
  }

  updateFromEvent(event) {
    const rect  = this.trackTarget.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width))
    const n     = Math.max(2, this.stepsValue)
    const idx   = Math.round(ratio * (n - 1))
    if (idx !== this.indexValue) {
      this.indexValue = idx
      this.render()
    }
  }

  render() {
    const n     = Math.max(2, this.stepsValue)
    const ratio = this.indexValue / (n - 1)
    const pct   = `${(ratio * 100).toFixed(2)}%`

    if (this.hasThumbTarget)   this.thumbTarget.style.left   = pct
    if (this.hasTooltipTarget) this.tooltipTarget.style.left = pct

    this.dotTargets.forEach((dot, i) =>
      dot.classList.toggle("active", i === this.indexValue)
    )

    if (this.hasTooltipTextTarget) {
      const label = this.labelTargets[this.indexValue]
      const text  = label ? (label.querySelector("[data-role='option']")?.textContent.trim() || label.textContent.trim() || "") : ""
      this.tooltipTextTarget.textContent = text || `Step ${this.indexValue + 1}`
    }
  }
}
