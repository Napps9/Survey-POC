import { Controller } from "@hotwired/stimulus"
import lottie from "lottie-web"

// Mounts a lottie-web instance and swaps the animation in response to
// `verto:scaleValue` events from the slider. Each value-swap destroys the
// previous animation and plays the next one from frame 0 (no loop).
// Animation URLs (one per slider value 1..N) are supplied as a JSON array
// in the `urls` value, so Rails can pass digested asset paths.
export default class extends Controller {
  static values  = { urls: Array, current: { type: Number, default: 1 } }
  static targets = ["mount"]

  connect() {
    this._onChange = (e) => this.show(e.detail.value)
    document.addEventListener("verto:scaleValue", this._onChange)
    this.show(this.currentValue)
  }

  disconnect() {
    document.removeEventListener("verto:scaleValue", this._onChange)
    this.instance?.destroy()
    this.instance = null
  }

  show(value) {
    const v = Number(value)
    if (!Number.isFinite(v) || v === this.shown) return
    const url = this.urlsValue[v - 1] // 1-indexed value
    if (!url) return
    this.shown = v
    this.instance?.destroy()
    this.instance = lottie.loadAnimation({
      container: this.mountTarget,
      renderer: "svg",
      loop: false,
      autoplay: true,
      path: url,
    })
  }
}
