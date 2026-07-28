import { Controller } from "@hotwired/stimulus"

// The Verto-score breakdown modal — opened from the score CTA in the
// editor's top-left chrome. The score board inside is filled by
// survey_editor_controller#refreshScore (same board, new home). Clicking a
// board row jumps to that card, so the modal closes to reveal it.
export default class extends Controller {
  static targets = ["overlay"]

  open() {
    if (!this.hasOverlayTarget) return
    // Dialog focus contract: remember the opener, move focus into the
    // dialog, and keep Tab cycling inside it until it closes.
    this._opener = document.activeElement
    this.overlayTarget.classList.remove("hidden")
    const dialog = this.overlayTarget.querySelector(".score-modal")
    if (dialog) {
      dialog.setAttribute("tabindex", "-1")
      dialog.focus()
    }
    this._trap = (e) => {
      if (e.key !== "Tab") return
      const focusables = [...this.overlayTarget.querySelectorAll(
        "button, [href], input, [tabindex]:not([tabindex='-1'])"
      )].filter(el => el.offsetParent !== null)
      if (!focusables.length) return
      const first = focusables[0]
      const last = focusables[focusables.length - 1]
      if (e.shiftKey && (document.activeElement === first || document.activeElement === dialog)) {
        e.preventDefault(); last.focus()
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault(); first.focus()
      }
    }
    this.overlayTarget.addEventListener("keydown", this._trap)
  }

  close() {
    if (!this.hasOverlayTarget) return
    this.overlayTarget.classList.add("hidden")
    if (this._trap) this.overlayTarget.removeEventListener("keydown", this._trap)
    if (this._opener && document.contains(this._opener)) this._opener.focus()
  }

  overlayClick(event) {
    if (event.target === this.overlayTarget) this.close()
    else if (event.target.closest(".score-row-main")) this.close()
  }

  closeOnEsc() {
    if (this.hasOverlayTarget && !this.overlayTarget.classList.contains("hidden")) this.close()
  }
}
