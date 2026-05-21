import { Controller } from "@hotwired/stimulus"

// Uploads / removes the organisation's logo from the Verto editor's Design
// panel, in the flow, without leaving the page. PATCHes organisations#update
// (multipart) and swaps the preview from the JSON response. The logo is
// org-level, so the change applies across all of the org's Vertos.
export default class extends Controller {
  static targets = ["input", "preview", "removeBtn", "status"]
  static values = { url: String, fallback: String }

  choose() {
    this.inputTarget.click()
  }

  async upload(event) {
    const file = event.target.files?.[0]
    if (!file) return
    const fd = new FormData()
    fd.append("organisation[logo]", file)
    await this._patch(fd, "Uploading…")
    event.target.value = ""
  }

  async remove() {
    const fd = new FormData()
    fd.append("organisation[remove_logo]", "1")
    await this._patch(fd, "Removing…")
  }

  async _patch(formData, pendingMsg) {
    this._status(pendingMsg)
    try {
      const res = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "",
          Accept: "application/json",
        },
        body: formData,
      })
      const data = await res.json()
      if (res.ok && data.ok) {
        this._setPreview(data.logo_url)
        this._status("Saved")
      } else {
        this._status(data.error || "Couldn't save")
      }
    } catch (_e) {
      this._status("Couldn't save")
    }
  }

  // logo_url is the org logo path, or null when reverted to the Playverto
  // wordmark (its asset path is passed in as the fallback value).
  _setPreview(logoUrl) {
    const img = this.previewTarget.querySelector("img")
    if (img) img.src = logoUrl || this.fallbackValue
    if (this.hasRemoveBtnTarget) this.removeBtnTarget.hidden = !logoUrl
  }

  _status(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }
}
