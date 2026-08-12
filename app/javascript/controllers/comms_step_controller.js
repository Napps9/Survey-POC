import { Controller } from "@hotwired/stimulus"

// A follow-up step's timing fields: debounced PATCH of delay + send window
// against the step's only-touch-present-keys endpoint.
export default class extends Controller {
  static targets = ["delay", "sendHour", "sendDay"]
  static values = { url: String }

  changed() {
    clearTimeout(this._timer)
    this._timer = setTimeout(() => this._persist(), 600)
  }

  disconnect() {
    clearTimeout(this._timer)
  }

  _persist() {
    if (!this.urlValue) return
    const body = {
      delay_minutes: parseInt(this.delayTarget.value, 10) || 0,
      send_hour: this.hasSendHourTarget && this.sendHourTarget.value !== "" ? parseInt(this.sendHourTarget.value, 10) : null,
      send_days: this.sendDayTargets.filter((c) => c.checked).map((c) => parseInt(c.value, 10))
    }
    try {
      fetch(this.urlValue, {
        method: "PATCH", keepalive: true,
        headers: {
          "Content-Type": "application/json", "Accept": "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        },
        body: JSON.stringify(body)
      })
    } catch (_) { /* next change retries */ }
  }
}
