import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// Textarea with live character counter. Counter turns hot-pink past max.
export default class extends Controller {
  static targets = ["input", "counter", "limit"]
  static values  = { max: { type: Number, default: 200 } }

  connect() { this.update() }

  // The limit is server-rendered into three places — this value, the textarea's
  // maxlength and the counter's own text — so changing the "Answer length"
  // select used to leave all three showing the old number until a full reload.
  // A creator who picked 500 was still told "0/200", and the textarea still
  // stopped them at 200. Stimulus calls this whenever the value changes, so
  // repainting here covers both setLimit below and anything else that writes it.
  maxValueChanged() { this.update() }

  // The select owns the limit; the textarea and the counter follow it.
  setLimit(event) {
    const next = parseInt(event.target.value, 10)
    if (!next) return
    this.maxValue = next
    if (this.hasInputTarget) this.inputTarget.maxLength = next
  }

  update() {
    const len = (this.inputTarget.value || "").length
    if (this.hasCounterTarget) {
      this.counterTarget.textContent = `${len}/${this.maxValue} ${t("card.characters")}`
      this.counterTarget.classList.toggle("over", len > this.maxValue)
    }
  }
}
