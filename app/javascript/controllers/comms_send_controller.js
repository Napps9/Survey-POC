import { Controller } from "@hotwired/stimulus"

// The Send panel's message fields (subject, preheader, from name, reply-to):
// a small debounced PATCH of just those keys against the campaign's
// only-touch-present-keys endpoint — the brand-palette shape.
//
// It also paints the inbox preview: the subject and preheader as a mail
// client will cut them. The truncation here is arithmetic, not judgement —
// every rule about what makes a subject good lives server-side in
// Comms::SubjectLine and arrives on the save response, so there is one set
// of rules rather than two that drift.
const WIDTHS = { desktop: 70, phone: 35 }
const SNIPPET_WIDTH = { desktop: 90, phone: 45 }

export default class extends Controller {
  static targets = ["subject", "preheader", "fromName", "replyTo", "variant",
                    "preview", "previewFrom", "previewSubject", "previewSnippet",
                    "previewDevice", "deviceToggle", "subjectCount", "review"]
  static values = { url: String, review: Array }

  connect() {
    this._device = "desktop"
    this._paintPreview()
    if (this.hasReviewValue) this._paintReview(this.reviewValue)
  }

  changed() {
    this._paintPreview()
    clearTimeout(this._timer)
    this._timer = setTimeout(() => this._persist(), 600)
  }

  toggleDevice() {
    this._device = this._device === "desktop" ? "phone" : "desktop"
    if (this.hasDeviceToggleTarget) {
      this.deviceToggleTarget.textContent =
        this._device === "desktop" ? "Show as phone" : "Show as desktop"
    }
    if (this.hasPreviewDeviceTarget) {
      this.previewDeviceTarget.textContent = this._device === "desktop" ? "Desktop" : "Phone"
    }
    this.previewTarget?.classList.toggle("is-phone", this._device === "phone")
    this._paintPreview()
  }

  disconnect() {
    clearTimeout(this._timer)
    this._persist()
  }

  _paintPreview() {
    if (!this.hasPreviewSubjectTarget) return
    const subject = this.hasSubjectTarget ? this.subjectTarget.value.trim() : ""
    const preheader = this.hasPreheaderTarget ? this.preheaderTarget.value.trim() : ""
    const width = WIDTHS[this._device]

    this.previewSubjectTarget.textContent = this._cut(subject, width) || "(no subject yet)"
    this.previewSubjectTarget.classList.toggle("is-empty", !subject)

    // With no preheader a client falls back to the top of the body, which is
    // what the empty state says rather than showing a blank line.
    this.previewSnippetTarget.textContent =
      preheader ? this._cut(preheader, SNIPPET_WIDTH[this._device]) : "(the top of your email shows here)"
    this.previewSnippetTarget.classList.toggle("is-empty", !preheader)

    if (this.hasPreviewFromTarget && this.hasFromNameTarget) {
      this.previewFromTarget.textContent = this.fromNameTarget.value.trim() || "Playverto"
    }
    if (this.hasSubjectCountTarget) {
      const count = this._len(subject)
      this.subjectCountTarget.textContent = `${count} / ${width}`
      this.subjectCountTarget.classList.toggle("is-over", count > width)
    }
  }

  // Code points, not UTF-16 units: an emoji is one character to a reader and
  // to Ruby's String#length, but two to JS's, so counting naively made the
  // panel's number disagree with the review's on the same subject.
  _len(value) {
    return [...value].length
  }

  _cut(value, width) {
    if (!value) return ""
    const chars = [...value]
    return chars.length <= width ? value : `${chars.slice(0, width).join("").trimEnd()}…`
  }

  _paintReview(notes) {
    if (!this.hasReviewTarget) return
    this.reviewTarget.innerHTML = ""
    for (const note of notes || []) {
      const li = document.createElement("li")
      li.className = `comms-review-${note.level === "warn" ? "warn" : "tip"}`
      li.textContent = note.text
      this.reviewTarget.appendChild(li)
    }
  }

  _persist() {
    if (!this.urlValue) return
    const body = {}
    if (this.hasSubjectTarget) body.subject = this.subjectTarget.value
    if (this.hasPreheaderTarget) body.preheader = this.preheaderTarget.value
    if (this.hasFromNameTarget) body.from_name = this.fromNameTarget.value
    if (this.hasReplyToTarget) body.reply_to = this.replyToTarget.value
    if (this.hasVariantTarget) {
      body.subject_variants = this.variantTargets.map((v) => v.value.trim()).filter(Boolean)
    }
    try {
      fetch(this.urlValue, {
        method: "PATCH", keepalive: true,
        headers: {
          "Content-Type": "application/json", "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify(body)
      })
        .then((r) => (r.ok ? r.json() : null))
        .then((data) => { if (data?.subject_review) this._paintReview(data.subject_review) })
        .catch(() => { /* next change retries */ })
    } catch (_) { /* next change retries */ }
  }
}
