import { Controller } from "@hotwired/stimulus"

// The Verto-score breakdown modal — opened from the score CTA in the
// editor's top-left chrome. The score board inside is filled by
// survey_editor_controller#refreshScore (same board, new home). Clicking a
// board row jumps to that card, so the modal closes to reveal it.
export default class extends Controller {
  static targets = ["overlay"]

  open() {
    if (this.hasOverlayTarget) this.overlayTarget.classList.remove("hidden")
  }

  close() {
    if (this.hasOverlayTarget) this.overlayTarget.classList.add("hidden")
  }

  overlayClick(event) {
    if (event.target === this.overlayTarget) this.close()
    else if (event.target.closest(".score-row-main")) this.close()
  }

  closeOnEsc() {
    if (this.hasOverlayTarget && !this.overlayTarget.classList.contains("hidden")) this.close()
  }
}
