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
    // On a submit event, event.target IS the form that was submitted.
    // Fall back to a DOM lookup so a manual call (no event) still works.
    const form = event?.target?.closest?.("form") || this.element.querySelector("form")
    const rawTheme   = form?.querySelector('[name="theme"]')?.value.trim()        || ""
    const rawAge     = form?.querySelector('[name="audience_age"]')?.value.trim() || ""
    const rawInsight = form?.querySelector('[name="key_insight"]')?.value.trim()  || ""

    // Required-field gate. Cancel the submit and shake the CTA so the
    // user gets a playful "nope" instead of a server-side flash bounce.
    if (!rawTheme || !rawAge || !rawInsight) {
      event?.preventDefault()
      this._shakeSubmit(form)
      return
    }

    const theme   = rawTheme   || "your Verto"
    const age     = rawAge
    const insight = rawInsight

    this._theme   = theme
    this._age     = age
    this._insight = insight

    if (this.hasPillAudienceTarget) this.pillAudienceTarget.textContent = age
    this.insightTextTarget.textContent = insight ? `"${insight}"` : ""

    // Stage 1 message — echo theme back as a forward-looking statement
    this._setHero(this._stage1Message(theme, age))
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
      this._setHero(this._stage2Message(this._theme, this._age))
      this.heroAgeTarget.textContent = ""
    }, STEP2_DONE_MS)

    setTimeout(() => {
      this._done(this.step3Target)
      this._active(this.step4Target)
      // Stage 3 — design rules applied
      this._setHero(this._stage3Message(this._theme, this._age))
      this.heroAgeTarget.textContent = ""
    }, STEP3_DONE_MS)

    setTimeout(() => {
      // Still waiting — soften the message
      this._setHero(this._stage4Message())
      this.heroAgeTarget.textContent = ""
    }, STEP4_HINT_MS)
  }

  // Set hero text and scale font-size so longer messages still fill
  // roughly the same on-screen area as shorter ones.
  _setHero(html) {
    const el = this.heroThemeTarget
    el.innerHTML = html
    const len = (el.textContent || "").length
    // Tuned around expected message lengths (~80–220 chars).
    // Shorter copy → bigger text; longer copy → smaller text.
    let fit
    if (len <= 100)       fit = 1.00
    else if (len <= 140)  fit = 0.90
    else if (len <= 180)  fit = 0.82
    else                  fit = 0.74
    el.style.setProperty("--hero-fit", fit)
  }

  // One concise phrase per step, reactive to the user's topic + audience.
  _audience(age) { return age ? `${age} year olds` : "your audience" }

  _topic(theme) {
    const t = String(theme ?? "").trim()
    const clipped = t.length > 48 ? `${t.slice(0, 47).trimEnd()}…` : t
    return this._esc(clipped)
  }

  _stage1Message(theme, age) {
    return `Writing questions on <em>${this._topic(theme)}</em> for ${this._audience(age)}`
  }

  _stage2Message(theme, age) {
    return `Choosing formats that keep <em>${this._audience(age)}</em> engaged`
  }

  _stage3Message(theme, age) {
    return `Tuning your <em>${this._topic(theme)}</em> Verto for ${this._audience(age)}`
  }

  _stage4Message() {
    return `Almost there — adding the final touches`
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

  _shakeSubmit(form) {
    const btn = form?.querySelector('input[type="submit"], button[type="submit"]')
    if (!btn) return
    btn.classList.remove("is-shaking")
    void btn.offsetWidth // restart the CSS animation
    btn.classList.add("is-shaking")
    btn.addEventListener("animationend", () => btn.classList.remove("is-shaking"), { once: true })
  }
}
