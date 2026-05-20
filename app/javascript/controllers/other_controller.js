import { Controller } from "@hotwired/stimulus"

// Toggles the "Other" free-text container on a question card. While open, the
// card is put into "other-active" mode (the normal answer is dimmed/ignored —
// the player's submitted answer becomes the free text). Closing clears the text
// so the respondent reverts to answering normally.
export default class extends Controller {
  static targets = ["panel", "btn"]

  toggle() {
    if (this.panelTarget.hidden) this._open()
    else this._close()
  }

  _open() {
    this.panelTarget.hidden = false
    this._card()?.classList.add("other-active")
    if (this.hasBtnTarget) this.btnTarget.classList.add("is-active")
    this.panelTarget.querySelector("textarea")?.focus()
  }

  _close() {
    this.panelTarget.hidden = true
    this._card()?.classList.remove("other-active")
    if (this.hasBtnTarget) this.btnTarget.classList.remove("is-active")
    const ta = this.panelTarget.querySelector("textarea")
    if (ta) {
      ta.value = ""
      ta.dispatchEvent(new Event("input")) // refresh the character counter
    }
  }

  _card() {
    return this.element.closest(".split-card") || this.element.closest(".preview-card")
  }
}
