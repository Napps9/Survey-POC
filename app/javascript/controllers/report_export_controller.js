import { Controller } from "@hotwired/stimulus"

// Generate + preview the AI results report in a modal, then download it as a PDF
// or save it to Google Drive. The Drive round-trip mirrors sheets-export: open
// the created file in a new tab, or bounce to the OAuth connect flow when the
// server reports the user needs to (re)connect.
export default class extends Controller {
  static targets = ["modal", "status", "body", "driveBtn", "driveStatus"]
  static values  = { reportUrl: String, driveUrl: String }

  open() {
    if (this.hasModalTarget) this.modalTarget.classList.remove("hidden")
    if (!this._loaded && !this._loading) this._load()
  }

  close() {
    if (this.hasModalTarget) this.modalTarget.classList.add("hidden")
  }

  backdrop(event) {
    if (event.target === this.modalTarget) this.close()
  }

  stop(event) { event.stopPropagation() }

  async _load() {
    this._loading = true
    this._setStatus("Generating your report…")
    try {
      const res  = await fetch(this.reportUrlValue, { headers: { "Accept": "application/json" } })
      const data = await res.json().catch(() => ({}))
      if (data.ok && data.body_html) {
        this.bodyTarget.innerHTML = data.body_html
        this._setStatus("")
        this._loaded = true
      } else {
        this._setStatus(data.error || "Couldn't generate the report.")
      }
    } catch (_) {
      this._setStatus("Couldn't generate the report.")
    }
    this._loading = false
  }

  async saveDrive() {
    if (this._saving) return
    this._saving = true
    this._setDrive("Saving to Drive…")
    if (this.hasDriveBtnTarget) this.driveBtnTarget.disabled = true
    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content
      const res  = await fetch(this.driveUrlValue, {
        method:  "POST",
        headers: { "Accept": "application/json", ...(csrf ? { "X-CSRF-Token": csrf } : {}) }
      })
      const data = await res.json().catch(() => ({}))
      if (data.ok && data.url) {
        window.open(data.url, "_blank", "noopener")
        this._setDrive("Saved to Drive ✓")
      } else if (data.reconnect && data.connect_url) {
        this._setDrive("Connecting Google…")
        window.location.href = data.connect_url
        return
      } else {
        this._setDrive(data.error || "Couldn't save to Drive.")
      }
    } catch (_) {
      this._setDrive("Couldn't save to Drive.")
    }
    this._saving = false
    if (this.hasDriveBtnTarget) this.driveBtnTarget.disabled = false
  }

  _setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
  _setDrive(text)  { if (this.hasDriveStatusTarget) this.driveStatusTarget.textContent = text }
}
