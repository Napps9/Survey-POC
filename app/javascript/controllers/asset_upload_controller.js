import { Controller } from "@hotwired/stimulus"

// Guards the brand-library upload before it becomes a request.
//
// The size and count limits are enforced server-side too, with friendly
// messages — but only for requests that reach the app. Selecting a large folder
// doesn't: Rack refuses a multipart body with more parts than its limit and
// answers a bare 400 *before* any controller runs, so the friendly
// "that would exceed your 60-asset limit" never gets a chance to fire. Holding
// the selection to the slots actually remaining keeps every rejection inside
// the app, where it can explain itself.
export default class extends Controller {
  static targets = ["input", "error", "submit"]
  static values  = { remaining: Number, maxBytes: Number, accept: String }

  check() {
    const files = Array.from(this.inputTarget.files || [])
    const problem = this._reject(files)

    this._show(problem)
    if (this.hasSubmitTarget) this.submitTarget.disabled = Boolean(problem)
  }

  _reject(files) {
    if (files.length === 0) return null

    if (this.remainingValue <= 0) {
      return "Your library is full — remove an asset before adding more."
    }
    if (files.length > this.remainingValue) {
      return `You picked ${files.length} files but only ${this.remainingValue} ` +
             `${this.remainingValue === 1 ? "slot is" : "slots are"} left — remove some, or pick fewer.`
    }

    const types = (this.acceptValue || "").split(",").filter(Boolean)
    const wrongType = files.find(f => types.length && f.type && !types.includes(f.type))
    if (wrongType) return `“${wrongType.name}” isn't a supported image — use PNG, JPG, GIF, SVG or WebP.`

    const tooBig = files.find(f => this.maxBytesValue && f.size > this.maxBytesValue)
    if (tooBig) return `“${tooBig.name}” is ${this._mb(tooBig.size)} — the limit is ${this._mb(this.maxBytesValue)} each.`

    return null
  }

  _mb(bytes) {
    const mb = bytes / (1024 * 1024)
    return `${mb >= 10 ? Math.round(mb) : mb.toFixed(1)} MB`
  }

  _show(message) {
    if (!this.hasErrorTarget) return
    this.errorTarget.textContent = message || ""
    this.errorTarget.hidden = !message
  }
}
