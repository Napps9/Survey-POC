import { Controller } from "@hotwired/stimulus"

// Auto-growing textarea: keeps a creator's text box tall enough to show
// everything they've typed, so longer answers/explanations are never clipped.
// The textarea's server-rendered height (its `rows`) is kept as the floor, and
// the box grows from there to fit the content.
//
// Some of these fields start inside a closed panel (consent / thank-you), so we
// never force a height while hidden — that would stick at 0 — and we re-grow as
// soon as the field becomes visible, so saved content isn't shown clipped.
export default class extends Controller {
  // single: a one-line field (name/theme/audience) that should still WRAP and
  // grow instead of scrolling sideways — so hard newlines aren't allowed.
  static values = { single: { type: Boolean, default: false } }

  connect() {
    const el = this.element
    el.style.overflowY = "hidden"
    el.style.resize    = "none"     // height is managed here now
    this._floor = el.offsetHeight   // rows-based height (0 if it starts hidden)
    this._grow  = this._grow.bind(this)
    el.addEventListener("input", this._grow)
    el.addEventListener("focus", this._grow)

    if (this.singleValue) {
      // Keep it one logical line: block Enter and strip any pasted newlines,
      // while still letting the text soft-wrap onto extra rows and grow.
      this._onKey = (e) => { if (e.key === "Enter") e.preventDefault() }
      this._strip = () => { if (el.value.includes("\n")) el.value = el.value.replace(/\s*\n\s*/g, " ") }
      el.addEventListener("keydown", this._onKey)
      el.addEventListener("input", this._strip)
    }

    if ("IntersectionObserver" in window) {
      this._io = new IntersectionObserver((entries) => {
        if (entries.some(e => e.isIntersecting)) {
          if (!this._floor) this._floor = el.offsetHeight
          this._grow()
        }
      })
      this._io.observe(el)
    }
    requestAnimationFrame(this._grow) // wait for layout so scrollHeight is real
  }

  disconnect() {
    this.element.removeEventListener("input", this._grow)
    this.element.removeEventListener("focus", this._grow)
    if (this._onKey) this.element.removeEventListener("keydown", this._onKey)
    if (this._strip) this.element.removeEventListener("input", this._strip)
    this._io?.disconnect()
  }

  _grow() {
    const el = this.element
    // No layout box (the field, or an ancestor panel, is hidden) — can't measure
    // content height, and pinning it to 0 would stick once shown.
    if (el.offsetParent === null) return
    el.style.height = "auto"
    el.style.height = `${Math.max(el.scrollHeight, this._floor)}px`
  }
}
