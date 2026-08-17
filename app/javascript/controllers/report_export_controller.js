import { Controller } from "@hotwired/stimulus"

// The AI results report modal: a 3-question brief (goal / audience / length)
// steers generation, the markdown streams in live, and the finished report can
// be edited in place (a markdown textarea — the stored format is markdown, and
// the PDF/Drive exports render from it server-side) or regenerated with a new
// brief. Download-as-PDF and save-to-Drive reuse the server-cached text, so
// they always reflect a saved edit.
export default class extends Controller {
  static targets = ["modal", "status", "body", "driveBtn", "driveStatus",
                    "brief", "goal", "audience", "length", "sectionBoxes",
                    "editor", "editBtn", "saveBtn", "regenBtn", "pdfBtn"]
  static values  = { streamUrl: String, driveUrl: String, saveUrl: String,
                     exists: Boolean, brief: String }

  open() {
    if (this.hasModalTarget) this.modalTarget.classList.remove("hidden")
    if (this._loaded || this._loading) return
    // A Verto with a cached report replays it; a fresh one asks the brief first.
    if (this.existsValue) this._load()
    else this._showBrief()
  }

  close() {
    if (this.hasModalTarget) this.modalTarget.classList.add("hidden")
  }

  backdrop(event) {
    if (event.target === this.modalTarget) this.close()
  }

  stop(event) { event.stopPropagation() }

  // ── Brief → generate ─────────────────────────────────────────────────────

  generate() {
    const params = new URLSearchParams({ regenerate: "1" })
    const goal     = this.hasGoalTarget     ? this.goalTarget.value.trim()     : ""
    const audience = this.hasAudienceTarget ? this.audienceTarget.value.trim() : ""
    const length   = this.hasLengthTarget   ? this.lengthTarget.value          : ""
    // The executive summary is always included server-side regardless of
    // these — this is only the three optional sections.
    const sections = this.sectionBoxesTargets.filter((b) => b.checked).map((b) => b.value)
    if (goal)     params.set("goal", goal)
    if (audience) params.set("audience", audience)
    if (length)   params.set("length", length)
    sections.forEach((s) => params.append("sections[]", s))
    // Keep the local copy in step with what the server will persist, so a
    // later Regenerate prefills the brief the creator actually used.
    this.briefValue = JSON.stringify({ goal, audience, length, sections })
    this._hideBrief()
    this._load(`${this.streamUrlValue}?${params}`)
  }

  regenerate() {
    if (this._loading) return
    this._loaded = false
    this.bodyTarget.innerHTML = ""
    this._exitEditMode()
    this._setReportActions(false)
    this._showBrief()
  }

  _showBrief() {
    if (!this.hasBriefTarget) return
    let saved = {}
    try { saved = JSON.parse(this.briefValue || "{}") } catch (_) {}
    if (this.hasGoalTarget     && saved.goal)     this.goalTarget.value     = saved.goal
    if (this.hasAudienceTarget && saved.audience) this.audienceTarget.value = saved.audience
    if (this.hasLengthTarget   && saved.length)   this.lengthTarget.value   = saved.length
    // No saved brief yet: leave every box at its checked-by-default markup
    // state. A saved brief always carries an explicit array — even an empty
    // one, from unchecking everything — so it fully overrides the markup.
    if (Array.isArray(saved.sections)) {
      this.sectionBoxesTargets.forEach((b) => { b.checked = saved.sections.includes(b.value) })
    }
    this.briefTarget.classList.remove("hidden")
  }

  _hideBrief() {
    if (this.hasBriefTarget) this.briefTarget.classList.add("hidden")
  }

  // ── Streamed generation ──────────────────────────────────────────────────

  // Stream the report markdown and render it live, so it types out as Claude
  // writes it (formatting appears as each heading/bullet arrives).
  async _load(url = this.streamUrlValue) {
    this._loading = true
    this._setStatus("Generating your report…")
    this.bodyTarget.innerHTML = ""
    try {
      const res = await fetch(url, { headers: { "Accept": "text/plain" } })
      // A 503 here means the instance is already streaming as much as it can
      // without starving ordinary requests — show the server's reason rather
      // than a generic failure, since retrying shortly genuinely works.
      if (!res.ok) throw new Error((await res.text()).trim() || "Couldn't generate the report.")
      if (!res.body) throw new Error("Couldn't generate the report.")

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

      this._md     = md
      this._loaded = md.trim().length > 0
      if (this._loaded) this._setReportActions(true)
      else this._setStatus("Couldn't generate the report.")
    } catch (_) {
      this._setStatus("Couldn't generate the report.")
    }
    this._loading = false
  }

  // ── Edit in place ────────────────────────────────────────────────────────

  edit() {
    if (!this._loaded || !this.hasEditorTarget) return
    this.editorTarget.value = this._md || ""
    this.bodyTarget.classList.add("hidden")
    this.editorTarget.classList.remove("hidden")
    this.editBtnTarget.classList.add("hidden")
    this.saveBtnTarget.classList.remove("hidden")
    this.editorTarget.focus()
  }

  async save() {
    if (this._saving) return
    const markdown = this.editorTarget.value
    if (!markdown.trim()) { this._setStatus("The report can't be empty."); return }
    this._saving = true
    this._setStatus("Saving…")
    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content
      const res  = await fetch(this.saveUrlValue, {
        method:  "PATCH",
        headers: { "Accept": "application/json", "Content-Type": "application/json",
                   ...(csrf ? { "X-CSRF-Token": csrf } : {}) },
        body: JSON.stringify({ markdown })
      })
      const data = await res.json().catch(() => ({}))
      if (data.ok) {
        this._md = markdown
        this.bodyTarget.innerHTML = data.body_html || this._mdToHtml(markdown)
        this._exitEditMode()
        this._setStatus("Saved ✓")
      } else {
        this._setStatus(data.error || "Couldn't save the report.")
      }
    } catch (_) {
      this._setStatus("Couldn't save the report.")
    }
    this._saving = false
  }

  _exitEditMode() {
    if (!this.hasEditorTarget) return
    this.editorTarget.classList.add("hidden")
    this.bodyTarget.classList.remove("hidden")
    if (this.hasSaveBtnTarget) this.saveBtnTarget.classList.add("hidden")
    if (this.hasEditBtnTarget && this._loaded) this.editBtnTarget.classList.remove("hidden")
  }

  _setReportActions(on) {
    if (this.hasEditBtnTarget)  this.editBtnTarget.classList.toggle("hidden", !on)
    if (this.hasRegenBtnTarget) this.regenBtnTarget.classList.toggle("hidden", !on)
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

  // ── Render downloads (PDF report, PDF share card) ─────────────────────────
  // Both renders spawn a wkhtmltopdf process using 100-200MB transiently, so
  // each happens in a job rather than on the request thread — ask for one,
  // watch it, then collect the file. Same create endpoint, differing only in
  // the `kind` sent (see ReportRendersController#create / ReportRender::KINDS).
  async downloadPdf(event) {
    return this._requestRender(event, "report")
  }

  // The share card: a compact, figures-only single page — no AI step, so it
  // never needs a report to already exist (see RenderInfographicJob).
  async downloadInfographic(event) {
    return this._requestRender(event, "infographic")
  }

  async _requestRender(event, kind) {
    event.preventDefault()
    const btn = event.currentTarget
    const url = btn.dataset.reportExportRenderUrl
    if (!url || btn.disabled) return

    const original = btn.textContent
    btn.disabled = true
    btn.textContent = "Preparing…"

    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content
      const res  = await fetch(url, {
        method: "POST",
        headers: { "Accept": "application/json", "Content-Type": "application/json",
                   ...(csrf ? { "X-CSRF-Token": csrf } : {}) },
        body: JSON.stringify({ kind })
      })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Couldn't start the download")

      const href = await this._awaitRender(data.poll_url)
      // A plain navigation, so the browser handles it as a download and the
      // modal stays exactly as the creator left it.
      window.location = href
    } catch (err) {
      this._setStatus(err.message)
    } finally {
      btn.disabled = false
      btn.textContent = original
    }
  }

  // Resolves to the download URL, or throws with a reason to show.
  async _awaitRender(pollUrl) {
    const deadline = Date.now() + 120000 // the render itself is seconds; this is a backstop
    while (Date.now() < deadline) {
      const res  = await fetch(pollUrl, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (data.download_url) return data.download_url
      if (data.status === "failed") throw new Error(data.error || "That file couldn't be built.")
      await new Promise(r => setTimeout(r, 1200))
    }
    throw new Error("That took longer than expected — please try again.")
  }

  _setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
  _setDrive(text)  { if (this.hasDriveStatusTarget) this.driveStatusTarget.textContent = text }
}
