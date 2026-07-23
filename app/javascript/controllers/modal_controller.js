import { Controller } from "@hotwired/stimulus"

// A minimal open/close modal — one panel, no chooser/form-panel swap like
// create-menu. Multiple independent instances can coexist on the same page.
export default class extends Controller {
  static targets = ["modal"]

  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.style.overflow = ""
  }

  closeOnEsc() {
    if (this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) this.close()
  }
}
