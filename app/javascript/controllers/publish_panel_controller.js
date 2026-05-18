import { Controller } from "@hotwired/stimulus"

// Toggles the right-hand column between the answer-type picker and the
// publish & share panel. The bottom-bar "Publish & share" CTA opens this
// view; the back button inside returns to the answer-type view.
export default class extends Controller {
  static targets = ["typeView", "publishView"]

  open() {
    this.typeViewTarget.classList.add("hidden")
    this.publishViewTarget.classList.remove("hidden")
  }

  close() {
    this.publishViewTarget.classList.add("hidden")
    this.typeViewTarget.classList.remove("hidden")
  }
}
