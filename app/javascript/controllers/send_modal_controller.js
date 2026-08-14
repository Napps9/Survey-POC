import { Controller } from "@hotwired/stimulus"

// The dashboard's Send modal. The panel itself is server-rendered
// (SurveyLinksController#show) into a Turbo Frame, so this controller only
// owns opening, closing and the one thing HTML can't express: whether the
// browser has an OS share sheet.
//
// The frame's src is cleared on close so reopening refetches — a link created
// or a switch flipped in one Verto's panel must not be what the next Verto's
// panel shows, and Turbo won't re-request a src it is already displaying.
export default class extends Controller {
  static targets = ["modal", "frame", "nativeShare"]

  open(event) {
    const url = event.currentTarget.dataset.sendUrl
    if (!url) return
    this.frameTarget.src = url
    this.modalTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.body.style.overflow = ""
    this.frameTarget.removeAttribute("src")
    this.frameTarget.innerHTML = ""
  }

  closeOnEsc() {
    if (this.hasModalTarget && !this.modalTarget.classList.contains("hidden")) this.close()
  }

  // Rendered hidden and revealed here: a share button that does nothing is
  // worse than no share button, and desktop Firefox has no navigator.share.
  nativeShareTargetConnected(el) {
    if (navigator.share) el.hidden = false
  }

  async nativeShare(event) {
    const el = event.currentTarget
    try {
      await navigator.share({
        title: el.dataset.shareTitle,
        text:  el.dataset.shareText,
        url:   el.dataset.shareUrl
      })
    } catch {
      // Dismissing the sheet rejects — indistinguishable from a real failure
      // and equally not worth reporting.
    }
  }
}
