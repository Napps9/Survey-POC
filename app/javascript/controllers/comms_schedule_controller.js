import { Controller } from "@hotwired/stimulus"

// The schedule form: datetime-local is the author's browser-local wall
// time; the server stores UTC. On submit the local value is converted to a
// UTC ISO string in the hidden field — no timezone column anywhere.
//
// A generated newsletter arrives with a suggested slot already on the draft
// (the Monday after it was written), so the input seeds from it and booking
// the send is one click. It is only ever a default: the author can change it
// or ignore it, and nothing is booked until they submit.
export default class extends Controller {
  static targets = ["input", "hidden"]
  static values = { suggested: String }

  connect() {
    if (!this.hasSuggestedValue || !this.suggestedValue) return
    if (!this.hasInputTarget || this.inputTarget.value) return

    const at = new Date(this.suggestedValue)
    if (isNaN(at)) return

    // datetime-local wants local wall time, not an ISO string with a zone.
    const local = new Date(at.getTime() - at.getTimezoneOffset() * 60000)
    this.inputTarget.value = local.toISOString().slice(0, 16)
  }

  submit(event) {
    const value = this.inputTarget.value
    if (!value) {
      event.preventDefault()
      return
    }
    this.hiddenTarget.value = new Date(value).toISOString()
  }
}
