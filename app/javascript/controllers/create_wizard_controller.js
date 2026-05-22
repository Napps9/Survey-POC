import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

export default class extends Controller {
  static targets = ["card", "back", "next", "finish", "counter"]
  static values  = { current: { type: Number, default: 0 } }

  connect() {
    this._wireValidation()
    this._update()
  }

  next(event) {
    if (event) event.preventDefault()
    if (!this._isStepValid(this.currentValue)) return
    if (this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
      this._update()
    }
  }

  back(event) {
    if (event) event.preventDefault()
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  _isStepValid(idx) {
    const card = this.cardTargets[idx]
    if (!card) return true
    const required = card.querySelectorAll("[data-required='true']")
    return Array.from(required).every(el => el.value.trim().length > 0)
  }

  _isFormValid() {
    return this.cardTargets.every((_, i) => this._isStepValid(i))
  }

  _wireValidation() {
    this.cardTargets.forEach(card => {
      const required = card.querySelectorAll("[data-required='true']")
      required.forEach(el => {
        el.addEventListener("input", () => this._updateButtons())
      })
    })
  }

  _update() {
    const total = this.cardTargets.length
    const idx   = this.currentValue
    this.cardTargets.forEach((c, i) => c.classList.toggle("active", i === idx))
    this.element.style.setProperty("--wizard-progress", `${Math.round(((idx + 1) / total) * 100)}%`)

    if (this.hasCounterTarget) {
      this.counterTarget.textContent = t("js.wizard.step_counter", { n: idx + 1, total })
    }
    if (this.hasBackTarget) {
      this.backTarget.classList.toggle("invisible", idx === 0)
    }
    const isLast = idx === total - 1
    if (this.hasNextTarget)   this.nextTarget.classList.toggle("hidden", isLast)
    if (this.hasFinishTarget) this.finishTarget.classList.toggle("hidden", !isLast)

    requestAnimationFrame(() => {
      const focusable = this.cardTargets[idx]?.querySelector("input[type='text'], textarea")
      if (focusable) focusable.focus({ preventScroll: true })
    })

    this._updateButtons()
  }

  _updateButtons() {
    const isLast = this.currentValue === this.cardTargets.length - 1
    if (isLast) {
      const valid = this._isFormValid()
      if (this.hasFinishTarget) {
        this.finishTarget.dataset.disabled = valid ? "false" : "true"
        this.finishTarget.disabled = !valid
      }
    } else {
      const valid = this._isStepValid(this.currentValue)
      if (this.hasNextTarget) {
        this.nextTarget.dataset.disabled = valid ? "false" : "true"
        this.nextTarget.disabled = !valid
      }
    }
  }
}
