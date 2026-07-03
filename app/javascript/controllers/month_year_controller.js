import { Controller } from "@hotwired/stimulus"

// Two-field month/year picker (the "When were you born?" demographic):
// digits-only entry, auto-advances from month to year once 2 digits are
// typed. See _card_component.html.erb for why this isn't a native
// <input type="month">.
export default class extends Controller {
  static targets = ["month", "year"]

  connect() {
    this.monthTarget.addEventListener("input", this._onMonth)
    this.yearTarget.addEventListener("input", this._onYear)
  }

  disconnect() {
    this.monthTarget.removeEventListener("input", this._onMonth)
    this.yearTarget.removeEventListener("input", this._onYear)
  }

  _onMonth = () => {
    this.monthTarget.value = this.monthTarget.value.replace(/\D/g, "").slice(0, 2)
    if (this.monthTarget.value.length === 2) this.yearTarget.focus()
  }

  _onYear = () => {
    this.yearTarget.value = this.yearTarget.value.replace(/\D/g, "").slice(0, 4)
  }
}
