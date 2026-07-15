import { Controller } from "@hotwired/stimulus"

// NPS "liquid container": an SVG vessel (.nps-vessel) whose liquid fills from
// the bottom as the respondent taps/holds and drags up or down. The .nps-liquid
// group rises via --nps-fill (set on .nps-control) — that rise/fall IS the
// drag feedback, so nothing else is overlaid on the vessel; the static label
// list shows the current selection (highlighted). The chosen value is the
// 0-indexed scale position, stored on `data-nps-value` for the player to
// read. NPS starts UNANSWERED — the container is empty until the first drag.
//
// Steps follow the label count (0–10 by default, but a 4/5-point or agree
// scale works too). Still emits `nps:valueChanged` (0-indexed value + 1..N
// `frame`) in case a reactive visual wants it; nothing listens today.
const FRAMES = 5

export default class extends Controller {
  static targets = ["label"]
  static values  = {
    steps: { type: Number, default: 11 },
    index: { type: Number, default: -1 },
    axis:  { type: String, default: "vertical" }
  }

  connect() {
    this._onMove = (e) => this._drag(e)
    this._onUp   = () => this._end()

    this.control = this.element.querySelector(".nps-control")

    if (this.indexValue >= 0) this._render(this.indexValue, { emit: false })
  }

  start(event) {
    if (event.target.isContentEditable) return
    event.preventDefault()
    event.stopPropagation() // don't also select/apply the type underneath
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
    const rect  = (this.control || this.element).getBoundingClientRect()
    const ratio = this.axisValue === "horizontal"
      ? (event.clientX - rect.left) / rect.width
      : (rect.bottom - event.clientY) / rect.height
    const r   = Math.max(0, Math.min(1, ratio))
    const n   = Math.max(2, this.stepsValue)
    const idx = Math.round(r * (n - 1))
    const changed = idx !== this.indexValue
    this.indexValue = idx
    this._render(idx, { emit: changed })
  }

  _render(idx, { emit }) {
    const ratio = this._ratioFor(idx)
    if (this.control) this.control.style.setProperty("--nps-fill", ratio.toFixed(3))

    const value = idx // 0-indexed: the answer IS the scale position (0..N-1)
    this.element.dataset.npsValue = value
    const lbl  = this.labelTargets[idx]
    const text = lbl ? lbl.textContent.trim() : `${value}`
    this.labelTargets.forEach((l, i) => l.classList.toggle("is-active", i === idx))
    this.element.setAttribute("aria-valuenow", value)
    this.element.setAttribute("aria-valuetext", text)

    if (emit) {
      const n = Math.max(2, this.stepsValue)
      const frame = Math.round((idx / (n - 1)) * (FRAMES - 1)) + 1
      document.dispatchEvent(new CustomEvent("nps:valueChanged", {
        detail: { value, index: idx, frame, text }
      }))
    }
  }

  _ratioFor(idx) {
    return this.stepsValue > 1 ? idx / (this.stepsValue - 1) : 0
  }
}
