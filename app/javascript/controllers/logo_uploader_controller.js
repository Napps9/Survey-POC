import { Controller } from "@hotwired/stimulus"

// Uploads / removes the organisation's logo from the Verto editor's Design
// panel, in the flow, without leaving the page. PATCHes organisations#update
// (multipart) and swaps the preview from the JSON response. The logo is
// org-level, so the change applies across all of the org's Vertos.
export default class extends Controller {
  static targets = ["input", "preview", "removeBtn", "status"]
  static values  = {
    url: String,
    fallback: String,
    // Mirrors of Organisation::LOGO_MAX_BYTES / LOGO_CONTENT_TYPES, passed in
    // from the view so the check here and the model's validation can't drift.
    maxBytes: Number,
    accept: String
  }

  choose() {
    this.inputTarget.click()
  }

  async upload(event) {
    const file = event.target.files?.[0]
    // Clear the input up front so picking the same file twice still fires
    // change — otherwise a rejected upload can't be retried without a detour.
    event.target.value = ""
    if (!file) return

    const problem = this._reject(file)
    if (problem) return this._status(problem)

    const fd = new FormData()
    fd.append("organisation[logo]", file)
    await this._patch(fd, "Uploading…")
  }

  async remove() {
    const fd = new FormData()
    fd.append("organisation[remove_logo]", "1")
    await this._patch(fd, "Removing…")
  }

  // Check what the server checks, before spending an upload on it: a rejection
  // the user can act on beats a round trip that comes back with a number.
  _reject(file) {
    const types = (this.acceptValue || "").split(",").filter(Boolean)
    if (types.length && file.type && !types.includes(file.type)) {
      return "That file type isn't supported — use a PNG, JPG, GIF, SVG or WebP."
    }
    if (this.maxBytesValue && file.size > this.maxBytesValue) {
      return `That image is ${this._mb(file.size)} — the limit is ${this._mb(this.maxBytesValue)}.`
    }
    return null
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

      // Parse a body only when the server says it is JSON. A rejected multipart
      // body, a redirect to sign-in, and a 500 all arrive as HTML or as nothing
      // at all — and calling res.json() on those throws. That throw used to be
      // caught and flattened into a bare "Couldn't save", which told the user
      // nothing and told us nothing either: the reason only existed in the
      // network tab, which is why this surfaced as an unexplained "400".
      const isJson = (res.headers.get("content-type") || "").includes("application/json")
      const data   = isJson ? await res.json().catch(() => null) : null

      if (res.ok && data?.ok) {
        this._setPreview(data.logo_url)
        this._status("Saved")
        return
      }
      this._status(data?.error || this._statusMessage(res.status))
    } catch (_e) {
      // Genuinely no response — DNS, offline, connection dropped mid-upload.
      this._status("Couldn't reach the server — check your connection and try again.")
    }
  }

  // A reason for the statuses that never carry a JSON body of their own.
  _statusMessage(status) {
    if (status === 401 || status === 403) return "You need admin access to change the logo."
    if (status === 413) return "That file is too large to upload."
    if (status >= 500)  return `Server error (${status}) — please try again.`
    return `Upload failed (${status}) — please try again.`
  }

  _mb(bytes) {
    const mb = bytes / (1024 * 1024)
    return `${mb >= 10 ? Math.round(mb) : mb.toFixed(1)} MB`
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
