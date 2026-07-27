import { Controller } from "@hotwired/stimulus"

// Polls a background Verto build and forwards to the editor when it lands.
//
// Generation takes 30-120s. It used to hold a Puma request thread for that long;
// now a job does the work and this watches the row. Because the state is in the
// database rather than this tab, a reload or a dropped connection resumes the
// same build instead of losing it.
export default class extends Controller {
  static targets = ["stalled"]
  static values  = { url: String }

  // Poll gently: the work takes tens of seconds, so a tighter interval would
  // just add requests to the instance we're trying to keep free.
  static INTERVAL_MS = 2000
  // Consecutive network failures before telling the user. The build itself is
  // unaffected by a failed poll, so this is about the page, not the work.
  static FAILURES_BEFORE_NOTICE = 5

  connect() {
    this._failures = 0
    this._stopped  = false
    this._tick()
  }

  disconnect() {
    this._stopped = true
    clearTimeout(this._timer)
  }

  async _tick() {
    if (this._stopped) return

    try {
      const res  = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      const data = await res.json()
      this._failures = 0
      this._hideStalled()

      if (data.redirect_to) {
        this._stopped = true
        window.location = data.redirect_to
        return
      }
      if (data.status === "failed") {
        // The HTML action turns a failed build into a redirect with the reason
        // in a flash, so just re-request this page rather than duplicating the
        // error copy here.
        this._stopped = true
        window.location.reload()
        return
      }
    } catch (_) {
      this._failures++
      if (this._failures >= this.constructor.FAILURES_BEFORE_NOTICE) this._showStalled()
    }

    this._timer = setTimeout(() => this._tick(), this.constructor.INTERVAL_MS)
  }

  _showStalled() {
    this.stalledTarget?.classList.remove("hidden")
  }

  _hideStalled() {
    this.stalledTarget?.classList.add("hidden")
  }
}
