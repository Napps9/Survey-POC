import { Controller } from "@hotwired/stimulus"

// Verto slider: track with N dots, draggable thumb. Snaps to the nearest
// step on release. Horizontal by default; axisValue "vertical" flips the
// drag math and positions the thumb via `bottom` instead of `left` — dots
// are positioned once at render time by the server/JS builder (see
// _card_component.html.erb / sliderHtml in type_panel_controller.js), so
// only the thumb needs runtime axis awareness.
//
// It also drives the left-panel reaction animation on Range cards: each step
// change dispatches `verto:scaleValue` with a 1–5 value (the slider's 3–5
// steps mapped proportionally onto the 5 animation frames), which the
// lottie-player controller listens for.
const REACTION_FRAMES = 5

export default class extends Controller {
  static targets = ["track", "thumb", "dot", "label"]
  static values  = {
    steps: Number,
    index: { type: Number, default: 0 },
    axis:  { type: String, default: "horizontal" }
  }

  connect() {
    this._onMove = this.onMove.bind(this)
    this._onUp   = this.onUp.bind(this)
    this.indexValue = Math.floor((this.stepsValue - 1) / 2)
    this.render()
    this._dispatchScaleValue() // sync the reaction animation to the start position
  }

  start(event) {
    if (event.target.isContentEditable) return
    event.preventDefault()
    event.stopPropagation() // don't also select/apply the type underneath
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
    const rect = this.trackTarget.getBoundingClientRect()
    const raw  = this.axisValue === "vertical"
      ? (rect.bottom - event.clientY) / rect.height
      : (event.clientX - rect.left) / rect.width
    const ratio = Math.max(0, Math.min(1, raw))
    const n     = Math.max(2, this.stepsValue)
    const idx   = Math.round(ratio * (n - 1))
    if (idx !== this.indexValue) {
      this.indexValue = idx
      this.render()
      this._dispatchScaleValue()
    }
  }

  // Map the current step (0…n-1) onto a 1…5 frame and broadcast it for the
  // reaction animation. Global document event, matching the player's
  // one-card-on-screen model.
  _dispatchScaleValue() {
    const n     = Math.max(2, this.stepsValue)
    const ratio = n > 1 ? this.indexValue / (n - 1) : 0
    const value = Math.round(ratio * (REACTION_FRAMES - 1)) + 1
    document.dispatchEvent(new CustomEvent("verto:scaleValue", { detail: { value } }))
  }

  render() {
    const n     = Math.max(2, this.stepsValue)
    const ratio = this.indexValue / (n - 1)
    const pct   = `${(ratio * 100).toFixed(2)}%`

    if (this.hasThumbTarget) {
      if (this.axisValue === "vertical") {
        this.thumbTarget.style.bottom = pct
        this.thumbTarget.style.left   = ""
      } else {
        this.thumbTarget.style.left   = pct
        this.thumbTarget.style.bottom = ""
      }
    }

    this.dotTargets.forEach((dot, i) =>
      dot.classList.toggle("active", i === this.indexValue)
    )
  }
}
