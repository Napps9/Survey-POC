import { Controller } from "@hotwired/stimulus"

// Device preview toggle for the editor. Swaps a device-* class on the cards
// feed so the split-cards reframe to phone / tablet width (CSS in
// application.css). The cards stay the same editable DOM, so clicking a card
// to change its type, deleting, and adding all keep working at any size.
export default class extends Controller {
  static targets = ["feed", "btn"]

  set(e) {
    const device = e.currentTarget.dataset.device || "desktop"
    this.feedTarget.classList.remove("device-desktop", "device-tablet", "device-mobile")
    this.feedTarget.classList.add(`device-${device}`)
    this.btnTargets.forEach(b => {
      const active = b.dataset.device === device
      b.classList.toggle("is-active", active)
      b.setAttribute("aria-pressed", active)
    })
  }
}
