import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "overlay", "heroTheme", "heroAge", "insightText", "pillAudience",
    "step1", "step2", "step3", "step4"
  ]

  show(event) {
    const form   = this.element.querySelector("form")
    const theme  = form?.querySelector('[name="theme"]')?.value.trim()       || "Your survey"
    const age    = form?.querySelector('[name="audience_age"]')?.value.trim() || ""
    const insight= form?.querySelector('[name="key_insight"]')?.value.trim()  || ""

    this.heroThemeTarget.innerHTML  = `<em>${this._esc(theme)}</em>`
    this.heroAgeTarget.textContent  = age ? `for ${age} year olds` : ""
    this.insightTextTarget.textContent = insight ? `"${insight}"` : ""
    if (this.hasPillAudienceTarget) this.pillAudienceTarget.textContent = age

    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")

    this._runSteps()
  }

  _runSteps() {
    setTimeout(() => this._done(this.step2Target), 1100)
    setTimeout(() => this._active(this.step3Target), 1200)
    setTimeout(() => {
      this._done(this.step3Target)
      this._active(this.step4Target)
      this.heroThemeTarget.textContent = "Almost there…"
      this.heroAgeTarget.textContent   = "applying Playverto design rules"
    }, 2400)
    setTimeout(() => {
      this._done(this.step4Target)
      this.heroThemeTarget.textContent = "Your Verto is ready!"
      this.heroAgeTarget.textContent   = ""
    }, 3600)
  }

  _done(el) {
    el.dataset.state = "done"
    el.querySelector(".step-dot").textContent = "✓"
  }

  _active(el) {
    el.dataset.state = "active"
    el.querySelector(".step-dot").textContent = ""
  }

  _esc(str) {
    return str.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;")
  }
}
