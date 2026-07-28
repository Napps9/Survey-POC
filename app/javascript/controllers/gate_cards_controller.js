import { Controller } from "@hotwired/stimulus"

// In-feed consent-gate and thank-you cards. Each lives in the cards feed as
// an editable replica of the player's design: a CTA (styled like Add
// question) sits above the welcome card / below the last card until the
// creator adds one, then the card itself shows with contenteditable text.
// Text persists to consent_text / thankyou_title / thankyou_body via
// update_settings (the same endpoint as the publish panel's settings forms),
// debounced like the card autosave. Save state is relayed to the top-left
// status pill through the gate-cards:status event (survey-editor#gateStatus).
export default class extends Controller {
  static targets = [
    "consentCta", "consentCard", "consentBody",
    "tyCta", "tyCard", "tyTitle", "tyBody"
  ]
  static values = { url: String }

  addConsent() {
    this.consentCtaTarget.hidden = true
    this.consentCardTarget.hidden = false
    const body = this.consentBodyTarget
    if (!body.textContent.trim()) body.textContent = body.dataset.defaultText || ""
    this._focusEnd(body)
    this._save({ consent_text: body.textContent.trim() })
  }

  removeConsent() {
    this.consentCardTarget.hidden = true
    this.consentCtaTarget.hidden = false
    this.consentBodyTarget.textContent = this.consentBodyTarget.dataset.defaultText || ""
    this._save({ consent_text: "" })
  }

  queueConsentSave() {
    clearTimeout(this._consentTimer)
    this._consentTimer = setTimeout(() =>
      this._save({ consent_text: this.consentBodyTarget.textContent.trim() }), 900)
  }

  addThankyou() {
    this.tyCtaTarget.hidden = true
    this.tyCardTarget.hidden = false
    this._focusEnd(this.tyTitleTarget)
    this._saveThankyou()
  }

  removeThankyou() {
    this.tyCardTarget.hidden = true
    this.tyCtaTarget.hidden = false
    // Back to the player defaults, which is what the reopened card shows.
    this.tyTitleTarget.textContent = this.tyTitleTarget.dataset.defaultText || ""
    this.tyBodyTarget.textContent = this.tyBodyTarget.dataset.defaultText || ""
    this._save({ thankyou_title: "", thankyou_body: "" })
  }

  queueThankyouSave() {
    clearTimeout(this._tyTimer)
    this._tyTimer = setTimeout(() => this._saveThankyou(), 900)
  }

  blockEnter(event) {
    event.preventDefault()
  }

  _saveThankyou() {
    this._save({
      thankyou_title: this.tyTitleTarget.textContent.trim(),
      thankyou_body: this.tyBodyTarget.textContent.trim()
    })
  }

  async _save(fields) {
    if (!this.hasUrlValue || !this.urlValue) return
    this.dispatch("status", { detail: { state: "saving" } })
    try {
      const fd = new FormData()
      Object.entries(fields).forEach(([k, v]) => fd.append(k, v))
      const res = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
          "Accept": "application/json"
        },
        body: fd
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      this.dispatch("status", { detail: { state: "saved", time: new Date().toLocaleTimeString() } })
    } catch (err) {
      this.dispatch("status", { detail: { state: "error", msg: err.message } })
    }
  }

  _focusEnd(el) {
    el.focus()
    const range = document.createRange()
    range.selectNodeContents(el)
    range.collapse(false)
    const sel = window.getSelection()
    sel.removeAllRanges()
    sel.addRange(range)
  }
}
