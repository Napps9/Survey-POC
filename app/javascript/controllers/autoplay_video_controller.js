import { Controller } from "@hotwired/stimulus"

// Plays a card's autoplaying background video ONLY while it's on screen, and
// pauses (and never pre-loads) it otherwise. This is what keeps a Verto full of
// videos from hammering bandwidth: the editor feed holds ~16 cards at once, but
// at most the one or two in the viewport ever fetch a byte.
//
// The element is the <video> itself: muted + loop + playsinline + preload="none"
// with a poster, so nothing loads until the card scrolls into view.
export default class extends Controller {
  connect() {
    this.video = this.element
    this.video.muted = true // required for autoplay; belt-and-braces

    if ("IntersectionObserver" in window) {
      this._io = new IntersectionObserver(
        (entries) => entries.forEach((e) => (e.isIntersecting ? this._play() : this._pause())),
        { threshold: 0.35 }
      )
      this._io.observe(this.video)
    } else {
      this._play() // no IO support — just autoplay
    }
  }

  disconnect() {
    this._io?.disconnect()
    this._pause()
  }

  _play() {
    // Defer loading until the clip is actually needed.
    if (this.video.preload === "none") this.video.preload = "auto"
    const p = this.video.play()
    if (p && typeof p.catch === "function") p.catch(() => {}) // ignore autoplay rejections
  }

  _pause() {
    try { this.video.pause() } catch (_e) { /* element may be detached */ }
  }
}
