import { Controller } from "@hotwired/stimulus"

// The Send panel's message fields (subject, preheader, from name, reply-to):
// a small debounced PATCH of just those keys against the campaign's
// only-touch-present-keys endpoint — the brand-palette shape.
export default class extends Controller {
  static targets = ["subject", "preheader", "fromName", "replyTo"]
  static values = { url: String }

  changed() {
    clearTimeout(this._timer)
    this._timer = setTimeout(() => this._persist(), 600)
  }

  disconnect() {
    clearTimeout(this._timer)
    this._persist()
  }

  _persist() {
    if (!this.urlValue) return
    const body = {}
    if (this.hasSubjectTarget) body.subject = this.subjectTarget.value
    if (this.hasPreheaderTarget) body.preheader = this.preheaderTarget.value
    if (this.hasFromNameTarget) body.from_name = this.fromNameTarget.value
    if (this.hasReplyToTarget) body.reply_to = this.replyToTarget.value
    try {
      fetch(this.urlValue, {
        method: "PATCH", keepalive: true,
        headers: {
          "Content-Type": "application/json", "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify(body)
      })
    } catch (_) { /* next change retries */ }
  }
}
