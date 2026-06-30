import { Controller } from "@hotwired/stimulus"

// NPS 0–10 scale: a horizontal row of number tiles (the label targets). Tap a
// tile or drag across the row to select; arrow keys step. The chosen value is
// the number itself (0..10), stored on `data-nps-value` for the player to
// read. NPS starts UNANSWERED — no tile is active until the respondent picks.
//
// It still emits `nps:valueChanged` (with the 0..10 value and a 1..5 `frame`)
// in case a reactive visual wants it; nothing listens today.
const FRAMES = 5

export default class extends Controller {
  static targets = ["label"]
  static values  = {
    steps: { type: Number, default: 11 },
    index: { type: Number, default: -1 }
  }

  connect() {
    this._onMove = (e) => this._drag(e)
    this._onUp   = () => this._end()
    // Render only a pre-existing selection; otherwise leave it unanswered.
    if (this.indexValue >= 0) this._render(this.indexValue, { emit: false })
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
    const from = this.indexValue < 0 ? (up ? -1 : 1) : this.indexValue
    const next = Math.max(0, Math.min(n - 1, from + (up ? 1 : -1)))
    const changed = next !== this.indexValue
    this.indexValue = next
    this._render(next, { emit: changed })
  }

  _drag(event) { if (this.dragging) this._fromEvent(event) }

  _end() {
    this.dragging = false
    window.removeEventListener("pointermove", this._onMove)
  }

  _fromEvent(event) {
    const rect  = this.element.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width))
    const n     = Math.max(2, this.stepsValue)
    const idx   = Math.round(ratio * (n - 1))
    const changed = idx !== this.indexValue
    this.indexValue = idx
    this._render(idx, { emit: changed })
  }

  _render(idx, { emit }) {
    const value = idx // 0-indexed: the answer IS the number (0..10)
    this.element.dataset.npsValue = value
    this.labelTargets.forEach((l, i) => l.classList.toggle("is-active", i === idx))
    this.element.setAttribute("aria-valuenow", value)
    const lbl = this.labelTargets[idx]
    this.element.setAttribute("aria-valuetext", lbl ? lbl.textContent.trim() : String(value))

    if (emit) {
      const n = Math.max(2, this.stepsValue)
      const frame = Math.round((idx / (n - 1)) * (FRAMES - 1)) + 1
      document.dispatchEvent(new CustomEvent("nps:valueChanged", {
        detail: { value, index: idx, frame }
      }))
    }
  }
}
