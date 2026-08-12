import { Controller } from "@hotwired/stimulus"

// Polls a campaign's status JSON every 2s while it is sending (the
// verto_build_controller shape) and paints the counts; stops on a terminal
// status and reloads once so the page swaps into its sent/report state.
export default class extends Controller {
  static targets = ["state", "counts"]
  static values = { url: String, status: String }

  static TERMINAL = ["sent", "failed", "cancelled", "draft", "scheduled"]

  connect() {
    this._failures = 0
    if (this.statusValue === "sending") this._start()
  }

  disconnect() {
    clearInterval(this._interval)
  }

  _start() {
    this._interval = setInterval(() => this._tick(), 2000)
  }

  async _tick() {
    try {
      const res = await fetch(this.urlValue, { headers: { "Accept": "application/json" } })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const json = await res.json()
      this._failures = 0
      this._paint(json)
      if (this.constructor.TERMINAL.includes(json.status)) {
        clearInterval(this._interval)
        window.location.reload()
      }
    } catch (_) {
      this._failures += 1
      if (this._failures >= 5 && this.hasStateTarget) {
        this.stateTarget.textContent = "Connection lost — retrying…"
      }
    }
  }

  _paint(json) {
    if (this.hasStateTarget) this.stateTarget.textContent = json.status
    if (!this.hasCountsTarget) return
    const c = json.counts || {}
    const done = (c.sent || 0) + (c.delivered || 0) + (c.simulated || 0) + (c.failed || 0) + (c.skipped || 0)
    this.countsTarget.textContent = `${done} / ${json.recipient_count} processed` +
      (c.failed ? ` · ${c.failed} failed` : "")
  }
}
