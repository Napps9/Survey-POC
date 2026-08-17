import { Controller } from "@hotwired/stimulus"

// POST a render request, poll until it's ready, then navigate to the
// download — a trimmed copy of report_export_controller.js's downloadPdf/
// _awaitPdf pair, for the public shared-results page. No CSRF token here:
// this controller only ever runs for an anonymous visitor, and
// SharedResultsController#create_render is a public, unauthenticated,
// rate-limited endpoint (skip_before_action :require_authentication on the
// whole controller, same as the player), so there is no session to protect.
export default class extends Controller {
  static targets = [ "button" ]
  static values  = { renderUrl: String }

  async download(event) {
    event.preventDefault()
    const btn = this.hasButtonTarget ? this.buttonTarget : event.currentTarget
    if (btn.disabled) return

    const original = btn.textContent
    btn.disabled = true
    btn.textContent = "Preparing…"

    try {
      const res  = await fetch(this.renderUrlValue, { method: "POST", headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (!data.ok) throw new Error(data.error || "Couldn't start the download")

      const href = await this._awaitPdf(data.poll_url)
      window.location = href
    } catch (err) {
      btn.textContent = err.message || "Something went wrong — please try again."
      setTimeout(() => { btn.textContent = original; btn.disabled = false }, 3000)
      return
    }
    btn.disabled = false
    btn.textContent = original
  }

  async _awaitPdf(pollUrl) {
    const deadline = Date.now() + 120000 // the render itself is seconds; this is a backstop
    while (Date.now() < deadline) {
      const res  = await fetch(pollUrl, { headers: { "Accept": "application/json" } })
      const data = await res.json()
      if (data.download_url) return data.download_url
      if (data.status === "failed") throw new Error(data.error || "That PDF couldn't be built.")
      await new Promise(r => setTimeout(r, 1200))
    }
    throw new Error("That took longer than expected — please try again.")
  }
}
