import { Controller } from "@hotwired/stimulus"

// Up/down reorder for prioritise rows. Rows are item targets; rank badges
// (data-role="rank-number") are renumbered after each move.
export default class extends Controller {
  static targets = ["item"]

  up(event)   { event.preventDefault(); this.move(event.currentTarget, -1) }
  down(event) { event.preventDefault(); this.move(event.currentTarget,  1) }

  move(button, delta) {
    const row = button.closest("[data-prioritise-target='item']")
    if (!row) return
    const list = row.parentElement
    const rows = Array.from(list.children)
    const idx  = rows.indexOf(row)
    const target = idx + delta
    if (target < 0 || target >= rows.length) return
    if (delta < 0) list.insertBefore(row, rows[target])
    else           list.insertBefore(row, rows[target].nextSibling)
    this.renumber()
  }

  renumber() {
    this.itemTargets.forEach((row, i) => {
      const badge = row.querySelector("[data-role='rank-number']")
      if (badge) badge.textContent = i + 1
    })
  }
}
