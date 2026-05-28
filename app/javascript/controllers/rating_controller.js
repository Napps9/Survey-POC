import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["star"]
  static values  = { index: { type: Number, default: -1 } }

  connect() { this._render() }

  pick(event) {
    if (event.target.isContentEditable) return
    event.stopPropagation()
    this.indexValue = parseInt(event.currentTarget.dataset.ratingIndex, 10)
    this._render()
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
      star.textContent = active ? "★" : "☆"
    })
  }
}
