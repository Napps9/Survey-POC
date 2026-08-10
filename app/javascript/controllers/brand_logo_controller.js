import { Controller } from "@hotwired/stimulus"

// A creator's logo that fails to load must vanish, not sit there as the
// browser's grey broken-image glyph. Respondents reported that glyph on the
// player's welcome and thank-you cards — a 34px box with a "?" in it, which
// reads as "this Verto is broken" long before anyone thinks "missing image".
//
// Deliberately cause-agnostic, because the cause isn't settled: the fetch can
// fail on a flaky mobile connection, on an expired signature, or because the
// blob's bytes are simply gone (a row survives a lost file — `attached?` only
// ever checked the row). brand_logo_tag and the service worker's cacheFirst
// each remove one of those; none of them can make bytes reappear. Whatever the
// reason, a logo that isn't there should simply not be there.
//
// Deliberately does NOT substitute the Playverto wordmark. The fallback in
// brand_logo_tag is for an org that never uploaded a logo; swapping OUR mark in
// where a client's own logo failed would put the wrong brand on their Verto,
// and on the thank-you card it would sit right above the "Powered by Playverto"
// wordmark that is already there.
export default class extends Controller {
  connect() {
    // The image can finish (and fail) before this lazily-loaded controller
    // connects, and a missed `error` event never fires again. A complete image
    // with no intrinsic width is one that failed.
    if (this.element.complete && this.element.naturalWidth === 0) this.failed()
  }

  failed() {
    this.element.hidden = true

    // Hide the wrapper too when the logo is all it holds (the player's
    // .split-right-logo row), so it doesn't leave a gap where a logo isn't.
    const wrap = this.element.parentElement
    if (wrap && wrap.children.length === 1) wrap.hidden = true
  }
}
