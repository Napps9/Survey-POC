import { Controller } from "@hotwired/stimulus"

// Calibrated for the typical Claude survey-generation latency (~8–14s).
// If the API takes longer, the final step keeps pulsing — Turbo will
// unmount this overlay when the response arrives.
const STEP2_DONE_MS = 4500   // "Writing questions" → done
const STEP3_DONE_MS = 9000   // "Picking formats"   → done
const STEP4_HINT_MS = 13000  // soften the message; we're still waiting

export default class extends Controller {
  static targets = [
    "overlay", "heroTheme", "heroAge", "insightText", "pillAudience",
    "step1", "step2", "step3", "step4"
  ]

  show(event) {
    const form    = this.element.querySelector("form")
    const theme   = form?.querySelector('[name="theme"]')?.value.trim()        || "Your survey"
    const age     = form?.querySelector('[name="audience_age"]')?.value.trim() || ""
    const insight = form?.querySelector('[name="key_insight"]')?.value.trim()  || ""

    this.heroThemeTarget.innerHTML     = `<em>${this._esc(theme)}</em>`
    this.heroAgeTarget.textContent     = age ? `for ${age} year olds` : ""
    this.insightTextTarget.textContent = insight ? `"${insight}"` : ""
    if (this.hasPillAudienceTarget) this.pillAudienceTarget.textContent = age

    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")

    this._runSteps()
  }

  _runSteps() {
    // Step 2: Writing questions → done; step 3 active
    setTimeout(() => {
      this._done(this.step2Target)
      this._active(this.step3Target)
    }, STEP2_DONE_MS)

    // Step 3: Picking formats → done; step 4 active
    setTimeout(() => {
      this._done(this.step3Target)
      this._active(this.step4Target)
    }, STEP3_DONE_MS)

    // If the API is taking a while, change the message but keep step 4 pulsing
    setTimeout(() => {
      this.heroAgeTarget.textContent = "applying Playverto design rules…"
    }, STEP4_HINT_MS)
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
