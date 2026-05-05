import { Controller } from "@hotwired/stimulus"

const STEP2_DONE_MS = 4500
const STEP3_DONE_MS = 9000
const STEP4_HINT_MS = 13000

export default class extends Controller {
  static targets = [
    "overlay", "heroTheme", "heroAge", "insightText", "pillAudience",
    "step1", "step2", "step3", "step4"
  ]

  show(event) {
    const form    = this.element.querySelector("form")
    const theme   = form?.querySelector('[name="theme"]')?.value.trim()        || "your survey"
    const age     = form?.querySelector('[name="audience_age"]')?.value.trim() || ""
    const insight = form?.querySelector('[name="key_insight"]')?.value.trim()  || ""

    this._theme   = theme
    this._age     = age
    this._insight = insight

    if (this.hasPillAudienceTarget) this.pillAudienceTarget.textContent = age
    this.insightTextTarget.textContent = insight ? `"${insight}"` : ""

    // Stage 1 message — echo theme back as a forward-looking statement
    this.heroThemeTarget.innerHTML = this._stage1Message(theme, age)
    this.heroAgeTarget.textContent = ""

    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")

    this._runSteps()
  }

  _runSteps() {
    setTimeout(() => {
      this._done(this.step2Target)
      this._active(this.step3Target)
      // Stage 2 — picking the right formats
      this.heroThemeTarget.innerHTML = this._stage2Message(this._theme, this._age)
      this.heroAgeTarget.textContent = ""
    }, STEP2_DONE_MS)

    setTimeout(() => {
      this._done(this.step3Target)
      this._active(this.step4Target)
      // Stage 3 — design rules applied
      this.heroThemeTarget.innerHTML = this._stage3Message(this._age, this._insight)
      this.heroAgeTarget.textContent = ""
    }, STEP3_DONE_MS)

    setTimeout(() => {
      // Still waiting — soften the message
      this.heroThemeTarget.innerHTML = this._stage4Message()
      this.heroAgeTarget.textContent = "Every question crafted. Putting the final touches on…"
    }, STEP4_HINT_MS)
  }

  // Each message reflects the user's actual input without just repeating it
  _stage1Message(theme, age) {
    const audience = age ? `${age} year olds` : "your audience"
    const messages = [
      `We're writing questions that reveal what <em>${audience}</em> genuinely think about ${this._esc(theme)}`,
      `Crafting 10–15 questions designed to surface the honest story behind <em>${this._esc(theme)}</em>`,
      `Every question is being built to get <em>${audience}</em> thinking — not just answering`,
    ]
    return messages[Math.floor(Math.random() * messages.length)]
  }

  _stage2Message(theme, age) {
    const audience = age ? `${age} year olds` : "your audience"
    const messages = [
      `Choosing the formats that'll keep <em>${audience}</em> engaged — sliders, swipe cards, image grids and more`,
      `Matching each question about <em>${this._esc(theme)}</em> to the format that gets the most honest response`,
      `Mixing question types so the survey stays fresh from card 1 to the last — no two consecutive formats are the same`,
    ]
    return messages[Math.floor(Math.random() * messages.length)]
  }

  _stage3Message(age, insight) {
    const audience = age ? `${age} year olds` : "respondents"
    const messages = [
      `Applying Playverto design rules — question length, option counts, and flow variety all tuned for <em>${audience}</em>`,
      insight
        ? `Making sure every card pushes toward uncovering <em>"${this._esc(insight)}"</em> without leading the answer`
        : `Balancing question order so momentum builds — and the most important insight lands at the right moment`,
      `Checking that no two identical formats appear back-to-back and every answer choice fits neatly on screen`,
    ]
    return messages[Math.floor(Math.random() * messages.length)]
  }

  _stage4Message() {
    return `Almost there — reviewing the full flow one last time`
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
    return String(str ?? "").replace(/&/g,"&amp;").replace(/</g,"&lt;")
                            .replace(/>/g,"&gt;").replace(/"/g,"&quot;")
  }
}
