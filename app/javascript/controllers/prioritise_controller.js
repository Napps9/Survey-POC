import { Controller } from "@hotwired/stimulus"

// Drag-to-rank list. Respondents drag rows into an order of priority (top =
// highest). Pointer-based so it works on touch and mouse. Reorders the DOM
// live and renumbers the rank badges; the player reads the row order at
// capture time. In the player the initial order is shuffled once, so the
// authored order isn't a systematic default.
export default class extends Controller {
  static targets = ["item", "rank"]
  static values  = { shuffle: { type: Boolean, default: false } }

  connect() {
    if (this.shuffleValue && !this._shuffled) {
      this._shuffleDom()
      this._shuffled = true
    }
    this._renumber()
  }

  start(event) {
    if (event.target.isContentEditable) return
    if (event.target.closest("button")) return // delete / add controls
    const item = event.currentTarget
    event.preventDefault()

    this.dragEl = item
    item.classList.add("is-dragging")
    try { item.setPointerCapture(event.pointerId) } catch (_) { /* older browsers */ }

    this._onMove = (e) => this._move(e)
    this._onUp   = () => this._end()
    window.addEventListener("pointermove", this._onMove)
    window.addEventListener("pointerup",   this._onUp, { once: true })
  }

  _move(event) {
    if (!this.dragEl) return
    const y = event.clientY
    const others = this.itemTargets.filter((i) => i !== this.dragEl)
    const before = others.find((o) => {
      const r = o.getBoundingClientRect()
      return y < r.top + r.height / 2
    })
    if (before) {
      this.element.insertBefore(this.dragEl, before)
    } else {
      const addBtn = this.element.querySelector(".pick-add-btn")
      addBtn ? this.element.insertBefore(this.dragEl, addBtn) : this.element.appendChild(this.dragEl)
    }
    this._renumber()
  }

  _end() {
    window.removeEventListener("pointermove", this._onMove)
    if (this.dragEl) this.dragEl.classList.remove("is-dragging")
    this.dragEl = null
    this._renumber()
    this.element.dataset.prioritiseTouched = "true"
    this.dispatch("changed") // editor: mark dirty
  }

  _renumber() {
    this.itemTargets.forEach((item, i) => {
      const badge = item.querySelector(".prioritise-rank")
      if (badge) badge.textContent = String(i + 1)
    })
  }

  _shuffleDom() {
    const addBtn = this.element.querySelector(".pick-add-btn")
    const items  = [...this.itemTargets]
    for (let i = items.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [items[i], items[j]] = [items[j], items[i]]
    }
    items.forEach((el) => (addBtn ? this.element.insertBefore(el, addBtn) : this.element.appendChild(el)))
  }
}
