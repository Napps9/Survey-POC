import { Controller } from "@hotwired/stimulus"

// The automation Trigger panel: debounced PATCH of the trigger fields
// (trigger type, delay, params, conditions, send window) against the
// automation's only-touch-present-keys endpoint. Shows the trigger-specific
// param sections for the picked type.
export default class extends Controller {
  static targets = ["triggerType", "delay", "inactiveDays", "orgSelect", "sendHour",
                    "sendDay", "section"]
  static values = { url: String }

  connect() {
    this._toggleSections()
  }

  disconnect() {
    clearTimeout(this._timer)
  }

  changed() {
    this._toggleSections()
    clearTimeout(this._timer)
    this._timer = setTimeout(() => this._persist(), 600)
  }

  _toggleSections() {
    const type = this.hasTriggerTypeTarget ? this.triggerTypeTarget.value : ""
    this.sectionTargets.forEach((s) => {
      s.hidden = s.dataset.triggerSection !== type
    })
  }

  _persist() {
    if (!this.urlValue) return
    const body = {
      trigger_type: this.triggerTypeTarget.value,
      delay_minutes: parseInt(this.delayTarget.value, 10) || 0,
      params: this.hasInactiveDaysTarget
        ? { inactive_days: parseInt(this.inactiveDaysTarget.value, 10) || 30 }
        : {},
      conditions: this.hasOrgSelectTarget
        ? { organisation_ids: Array.from(this.orgSelectTarget.selectedOptions).map((o) => parseInt(o.value, 10)) }
        : {},
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
