import { Controller } from "@hotwired/stimulus"

// The dashboard's "Create a Form" modal — its own peer flow next to
// "Start from a template" and "+ Create a new Verto", rather than a link
// into the generic wizard. Reopens itself after a server round-trip
// (an import error, or landing back here post-Google-connect) via the
// reopen value set from the view.
export default class extends Controller {
  static targets = ["modal", "urlInput"]
  static values = { reopen: Boolean }

  connect() {
    if (this.reopenValue) this.open()
  }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
    this.urlInputTarget?.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.style.overflow = ""
  }

  closeOnEsc() {
    if (this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) this.close()
  }
}
