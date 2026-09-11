import { Controller } from "@hotwired/stimulus"

// A minimal open/close modal — one panel, no chooser/form-panel swap like
// create-menu. Multiple independent instances can coexist on the same page.
export default class extends Controller {
  static targets = ["modal"]

  // A modal can arrive already open — rendered without `hidden` because the
  // server is bringing the viewer back INTO it (see the Language check share
  // modal, which reopens after a link is minted). Without this the page behind
  // it would still scroll, which open() is careful to prevent every other way
  // a modal can appear. No-op for the usual case of starting hidden.
  connect() {
    if (this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) {
      document.body.style.overflow = "hidden"
    }
  }

  disconnect() {
    document.body.style.overflow = ""
  }

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
