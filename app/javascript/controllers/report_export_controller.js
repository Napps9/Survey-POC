import { Controller } from "@hotwired/stimulus"

// Generate + preview the AI results report in a modal, then download it as a PDF
// or save it to Google Drive. The Drive round-trip mirrors sheets-export: open
// the created file in a new tab, or bounce to the OAuth connect flow when the
// server reports the user needs to (re)connect.
export default class extends Controller {
  static targets = ["modal", "status", "body", "driveBtn", "driveStatus"]
  static values  = { streamUrl: String, driveUrl: String }

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

  // Stream the report markdown and render it live, so it types out as Claude
  // writes it (formatting appears as each heading/bullet arrives).
  async _load() {
    this._loading = true
    this._setStatus("Generating your report…")
    this.bodyTarget.innerHTML = ""
    try {
      const res = await fetch(this.streamUrlValue, { headers: { "Accept": "text/plain" } })
      if (!res.ok || !res.body) throw new Error("stream failed")

      const reader = res.body.getReader()
      const dec    = new TextDecoder()
      let md = "", started = false
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        if (!started) { started = true; this._setStatus("") }
        md += dec.decode(value, { stream: true })
        this.bodyTarget.innerHTML = this._mdToHtml(md)
      }

      this._loaded = md.trim().length > 0
      if (!this._loaded) this._setStatus("Couldn't generate the report.")
    } catch (_) {
      this._setStatus("Couldn't generate the report.")
    }
    this._loading = false
  }

  // Minimal Markdown → HTML for the constrained report format (## / ### headings,
  // - bullet lists, **bold**, paragraphs). Re-parses the accumulated text each
  // chunk; the PDF / Google Doc use the server-side kramdown render.
  _mdToHtml(md) {
    const inline = (s) => this._esc(s).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    let html = "", inList = false
    const closeList = () => { if (inList) { html += "</ul>"; inList = false } }
    for (const line of md.split("\n")) {
      const t = line.trim()
      if (t.startsWith("### "))      { closeList(); html += `<h3>${inline(t.slice(4))}</h3>` }
      else if (t.startsWith("## "))  { closeList(); html += `<h2>${inline(t.slice(3))}</h2>` }
      else if (t.startsWith("# "))   { closeList(); html += `<h2>${inline(t.slice(2))}</h2>` }
      else if (/^[-*]\s+/.test(t))   { if (!inList) { html += "<ul>"; inList = true } html += `<li>${inline(t.replace(/^[-*]\s+/, ""))}</li>` }
      else if (t === "")             { closeList() }
      else                           { closeList(); html += `<p>${inline(t)}</p>` }
    }
    closeList()
    return html
  }

  _esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
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
