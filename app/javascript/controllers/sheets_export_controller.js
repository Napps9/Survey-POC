import { Controller } from "@hotwired/stimulus"

// Drives "Export to Google Sheets": POSTs the form, opens the created sheet in
// a new tab, and shows inline status. Sends users to the OAuth connect flow if
// the server reports they need to (re)connect.
export default class extends Controller {
  static targets = ["button", "status"]

  async submit(event) {
    event.preventDefault()
    if (this._loading) return
    this._loading = true
    this._setStatus("Creating sheet…")
    if (this.hasButtonTarget) this.buttonTarget.disabled = true

    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content
      const res  = await fetch(this.element.action, {
        method:  "POST",
        headers: { "Accept": "application/json", ...(csrf ? { "X-CSRF-Token": csrf } : {}) }
      })
      const data = await res.json().catch(() => ({}))

      if (data.ok && data.url) {
        window.open(data.url, "_blank", "noopener")
        this._setStatus("Sheet created ✓")
      } else if (data.reconnect && data.connect_url) {
        this._setStatus("Connecting Google…")
        window.location.href = data.connect_url
        return
      } else {
        this._setStatus(data.error || "Couldn't create the sheet.")
      }
    } catch (_) {
      this._setStatus("Couldn't create the sheet.")
    }

    this._loading = false
    if (this.hasButtonTarget) this.buttonTarget.disabled = false
  }

  _setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
