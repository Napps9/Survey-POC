import { Controller } from "@hotwired/stimulus"
import { haptic } from "lib/haptics"

export default class extends Controller {
  static targets = ["star"]
  static values  = { index: { type: Number, default: -1 } }

  connect() { this._render() }

  pick(event) {
    if (event.target.isContentEditable) return
    event.stopPropagation()
    this.indexValue = parseInt(event.currentTarget.dataset.ratingIndex, 10)
    this._render()
    haptic()
    this.dispatch("pick", { detail: { index: this.indexValue } })
  }

  hover(event) {
    this._highlight(parseInt(event.currentTarget.dataset.ratingIndex, 10))
  }

  unhover() { this._highlight(this.indexValue) }

  _render() { this._highlight(this.indexValue) }

  _highlight(upTo) {
    this.starTargets.forEach((star, i) => {
      const active = i <= upTo
      star.classList.toggle("active", active)
      // Themed icon glyphs ride on each star (star kind swaps ★/☆; emoji
      // kinds keep the same glyph and let CSS dim the inactive ones).
      const on  = star.dataset.ratingOn  || "★"
      const off = star.dataset.ratingOff || "☆"
      star.textContent = active ? on : off
    })
  }
}
