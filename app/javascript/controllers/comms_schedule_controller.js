import { Controller } from "@hotwired/stimulus"

// The schedule form: datetime-local is the author's browser-local wall
// time; the server stores UTC. On submit the local value is converted to a
// UTC ISO string in the hidden field — no timezone column anywhere.
export default class extends Controller {
  static targets = ["input", "hidden"]

  submit(event) {
    const value = this.inputTarget.value
    if (!value) {
      event.preventDefault()
      return
    }
    this.hiddenTarget.value = new Date(value).toISOString()
  }
}
