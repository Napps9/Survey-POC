import { Controller } from "@hotwired/stimulus"

// Drag-to-rank list. Respondents drag rows into an order of priority (top =
// highest). Pointer-based (touch + mouse) and FLUID: the dragged row follows
// the finger 1:1 while the other rows SLIDE to open a gap, and the drop
// animates into place. The DOM is only reordered once — invisibly — on
// release, so nothing ever snaps. In the player the initial order is shuffled
// once so the authored order isn't a systematic default.
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
    event.stopPropagation() // don't also select/apply the type underneath

    this.items       = this.itemTargets
    this.dragEl      = item
    this.startIndex  = this.items.indexOf(item)
    this.targetIndex = this.startIndex
    this.startY      = event.clientY
    this.maxIndex    = this.items.length - 1
    this._finished   = false

    // Row step = the distance between consecutive rows (height + gap). Assumes
    // similar-height rows, which the list is.
    const rects = this.items.map((el) => el.getBoundingClientRect())
    this.step = rects.length > 1
      ? Math.abs(rects[1].top - rects[0].top)
      : (rects[0]?.height || 56) + 8

    item.classList.add("is-dragging")
    item.style.transition = "none" // follow the finger 1:1
    item.style.zIndex = "10"
    try { item.setPointerCapture(event.pointerId) } catch (_) { /* older browsers */ }

    this._onMove   = (e) => this._move(e)
    this._onUp     = () => this._end()
    // The browser fires pointercancel when it claims the gesture for itself
    // (scroll, alert, tab switch). Without this handler the drag never ends:
    // the row stays stuck mid-air in .is-dragging, and the still-armed
    // pointerup commits a reorder on the next tap anywhere on the page.
    this._onCancel = () => this._cancel()
    window.addEventListener("pointermove",   this._onMove)
    window.addEventListener("pointerup",     this._onUp)
    window.addEventListener("pointercancel", this._onCancel)
  }

  // Both terminal paths (_end and _cancel) must drop ALL three window
  // listeners — a partial removal is exactly the stuck-pointerup bug above.
  _teardown() {
    window.removeEventListener("pointermove",   this._onMove)
    window.removeEventListener("pointerup",     this._onUp)
    window.removeEventListener("pointercancel", this._onCancel)
  }

  // Abandon the drag: the DOM was never reordered (only transforms moved
  // rows), so clearing styles restores the pre-drag order exactly. Nothing is
  // committed — no touched mark, no changed dispatch.
  _cancel() {
    this._teardown()
    const drag = this.dragEl
    if (!drag) return
    this.dragEl = null

    this.items.forEach((el) => { el.style.transition = ""; el.style.transform = ""; el.style.zIndex = "" })
    drag.classList.remove("is-dragging")
    this._renumber()
  }

  _move(event) {
    if (!this.dragEl) return
    const dy = event.clientY - this.startY
    this.dragEl.style.transform = `translateY(${dy}px) scale(1.02)`

    let idx = this.startIndex + Math.round(dy / this.step)
    idx = Math.max(0, Math.min(this.maxIndex, idx))
    if (idx !== this.targetIndex) {
      this.targetIndex = idx
      this._reflowGap()
    }
  }

  // Slide the non-dragged rows to open a gap at targetIndex.
  _reflowGap() {
    this.items.forEach((el, i) => {
      if (el === this.dragEl) return
      el.style.transition = "transform 0.18s cubic-bezier(.2,.7,.3,1)"
      let shift = 0
      if (this.targetIndex > this.startIndex && i > this.startIndex && i <= this.targetIndex) {
        shift = -this.step
      } else if (this.targetIndex < this.startIndex && i >= this.targetIndex && i < this.startIndex) {
        shift = this.step
      }
      el.style.transform = shift ? `translateY(${shift}px)` : ""
    })
    this._renumberVisual()
  }

  _end() {
    this._teardown()
    const drag = this.dragEl
    if (!drag) return
    this.dragEl = null // stop further moves

    // Animate the row into its resting slot, then commit the DOM order (which
    // matches what's on screen, so clearing transforms causes no jump).
    const restY = (this.targetIndex - this.startIndex) * this.step
    drag.style.transition = "transform 0.18s cubic-bezier(.2,.7,.3,1)"
    drag.style.transform  = `translateY(${restY}px)`

    const finish = () => {
      if (this._finished) return
      this._finished = true
      drag.removeEventListener("transitionend", finish)

      const order  = this.items.filter((el) => el !== drag)
      order.splice(Math.min(this.targetIndex, order.length), 0, drag)
      const addBtn = this.element.querySelector(".pick-add-btn")
      order.forEach((el) => (addBtn ? this.element.insertBefore(el, addBtn) : this.element.appendChild(el)))

      this.items.forEach((el) => { el.style.transition = ""; el.style.transform = ""; el.style.zIndex = "" })
      drag.classList.remove("is-dragging")
      this._renumber()
      this.element.dataset.prioritiseTouched = "true"
      this.dispatch("changed") // editor: mark dirty
    }
    drag.addEventListener("transitionend", finish, { once: true })
    setTimeout(finish, 240) // fallback when the transform doesn't change
  }

  _renumber() {
    this.itemTargets.forEach((item, i) => {
      const badge = item.querySelector(".prioritise-rank")
      if (badge) badge.textContent = String(i + 1)
    })
  }

  // Renumber to reflect the live (gapped) visual order during a drag.
  _renumberVisual() {
    const order = this.items.filter((el) => el !== this.dragEl)
    order.splice(Math.min(this.targetIndex, order.length), 0, this.dragEl)
    order.forEach((el, i) => {
      const badge = el.querySelector(".prioritise-rank")
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
