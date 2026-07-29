import { Controller } from "@hotwired/stimulus"

const STEP2_DONE_MS = 4500
const STEP3_DONE_MS = 9000
const STEP4_HINT_MS = 13000

// Drives the shared generating stage (shared/_generating_stage.html.erb) in
// two homes:
//
//  - the wizard's overlay (surveys/new): show() runs on form submit, reads the
//    brief straight from the form, and bridges the moment until the server
//    redirects to the build page;
//  - the build wait screen (verto_builds/show): autostart-value runs the same
//    theatre from the build's payload on connect, offset by the build's
//    elapsed time so a refresh resumes mid-story instead of restarting.
export default class extends Controller {
  static targets = [
    "overlay", "heroTheme", "insightText", "pillsRow", "pillAudience",
    "step1", "step2", "step3", "step4"
  ]

  static values = {
    autostart: Boolean,
    kind:      String,  // a VertoBuild kind — "generate" or an import_* variant
    theme:     String,
    age:       String,
    insight:   String,
    elapsed:   Number   // seconds since the build started, for resumed timing
  }

  connect() {
    if (!this.autostartValue) return

    const elapsedMs = Math.max(0, (this.elapsedValue || 0) * 1000)
    if (this.kindValue && this.kindValue !== "generate") {
      this._beginImport(this.kindValue.replace(/^import_/, ""), elapsedMs)
    } else {
      this._begin(this.themeValue, this.ageValue, this.insightValue, elapsedMs)
    }
  }

  disconnect() {
    this._timers?.forEach(clearTimeout)
  }

  show(event) {
    // On a submit event, event.target IS the form that was submitted.
    // Fall back to a DOM lookup so a manual call (no event) still works.
    const form = event?.target?.closest?.("form") || this.element.querySelector("form")

    // Import paths (manual paste, PDF, Google Form) all skip the theme/age/
    // insight brief gate below and show the generic "reading your questions"
    // overlay instead. Only the PDF door needs a pre-submit guard: it's the
    // first submit in the form, so a stray Enter keypress targets it too —
    // only proceed when a file is actually attached, otherwise let the user
    // keep filling the brief rather than posting an empty upload.
    const importKind = event?.submitter?.dataset?.generatingImport
    if (importKind) {
      if (importKind === "pdf") {
        const file = form?.querySelector('input[name="pdf"]')
        if (!file?.files?.length) {
          event?.preventDefault()
          this._shakeSubmit(event.submitter)
          return
        }
      }
      this._showOverlay()
      this._beginImport(importKind)
      return
    }

    // Required-field gate. The learning goal is an or/and with Common
    // Questions — either one unlocks generation. Cancel the submit and shake
    // the CTA so the user gets a playful "nope" instead of a server bounce.
    if (this.requiredFieldsMissing(form)) {
      event?.preventDefault()
      this._shakeSubmit(event?.submitter || form)
      return
    }

    this._showOverlay()
    this._begin(
      form?.querySelector('[name="theme"]')?.value        || "your Verto",
      form?.querySelector('[name="audience_age"]')?.value || "",
      form?.querySelector('[name="key_insight"]')?.value  || ""
    )
  }

  // Shared with demographics_gate_controller.js so it can skip its one-time
  // explainer modal (and let this method's own shake-the-CTA feedback show
  // instead) when the brief is incomplete — otherwise a first-time creator
  // sees an unrelated modal before ever finding out why Generate didn't work.
  requiredFieldsMissing(form) {
    const rawTheme   = form?.querySelector('[name="theme"]')?.value.trim()        || ""
    const rawAge     = form?.querySelector('[name="audience_age"]')?.value.trim() || ""
    const rawInsight = form?.querySelector('[name="key_insight"]')?.value.trim()  || ""
    const hasCommon  = !!form?.querySelector("input[name='common_question_ids[]']:checked")
    return !rawTheme || !rawAge || (!rawInsight && !hasCommon)
  }

  // ── The staged story ──────────────────────────────────────────────────────

  _begin(theme, age, insight, elapsedMs = 0) {
    this._import  = false
    this._theme   = String(theme ?? "").trim()
    this._age     = String(age ?? "").trim()
    this._insight = String(insight ?? "").trim()

    this.pillsRowTarget.classList.remove("hidden")
    if (this.hasPillAudienceTarget) this.pillAudienceTarget.textContent = this._age
    this.insightTextTarget.textContent = this._insight ? `"${this._insight}"` : ""

    this._runFrom(elapsedMs)
  }

  // Imports have no theme/age/insight to echo — hide the brief pills and tell
  // the reading-your-questions story instead, named for where they came from.
  _beginImport(kind, elapsedMs = 0) {
    this._import = true
    this._source = { pdf: "PDF", google_form: "Google Form" }[kind] || "questions"

    this.pillsRowTarget.classList.add("hidden")
    this.insightTextTarget.textContent = ""

    this._runFrom(elapsedMs)
  }

  // Apply whatever stage elapsedMs falls in right now, then schedule the rest.
  _runFrom(elapsedMs) {
    this._timers?.forEach(clearTimeout)
    this._timers = []

    this._setHero(this._stageMessage(this._stageFor(elapsedMs)))

    this._at(STEP2_DONE_MS, elapsedMs, () => {
      this._done(this.step2Target)
      this._active(this.step3Target)
      this._setHero(this._stageMessage(2))
    })
    this._at(STEP3_DONE_MS, elapsedMs, () => {
      this._done(this.step3Target)
      this._active(this.step4Target)
      this._setHero(this._stageMessage(3))
    })
    this._at(STEP4_HINT_MS, elapsedMs, () => {
      this._setHero(this._stageMessage(4))
    })
  }

  // Run fn at `atMs` on the build's clock: overdue moments run now (catching
  // step states up after a refresh), future ones are scheduled.
  _at(atMs, elapsedMs, fn) {
    const delay = atMs - elapsedMs
    if (delay <= 0) fn()
    else this._timers.push(setTimeout(fn, delay))
  }

  _stageFor(elapsedMs) {
    if (elapsedMs < STEP2_DONE_MS) return 1
    if (elapsedMs < STEP3_DONE_MS) return 2
    if (elapsedMs < STEP4_HINT_MS) return 3
    return 4
  }

  _showOverlay() {
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")
    document.body.classList.add("generating-overlay-active")
  }

  // Set hero text and scale font-size so longer messages still fill
  // roughly the same on-screen area as shorter ones.
  _setHero(html) {
    const el = this.heroThemeTarget
    el.innerHTML = html
    // Keep the phrase on a single line: shrink the font until it fits the
    // available width (falls back to ellipsis at the minimum scale).
    const avail = el.parentElement?.clientWidth || el.clientWidth || 680
    let fit = 1
    let guard = 0
    el.style.setProperty("--hero-fit", fit)
    while (el.scrollWidth > avail && fit > 0.5 && guard++ < 24) {
      fit -= 0.04
      el.style.setProperty("--hero-fit", fit)
    }
  }

  // One concise phrase per stage, reactive to the user's topic + audience.
  _audience(age) { return age ? this._esc(age) : "your audience" }

  _topic(theme) {
    const t = String(theme ?? "").trim()
    const clipped = t.length > 48 ? `${t.slice(0, 47).trimEnd()}…` : t
    return this._esc(clipped)
  }

  _stageMessage(stage) {
    if (this._import) {
      switch (stage) {
        case 1:  return `Reading your ${this._source} and matching question types`
        case 2:  return `Choosing the best card for each question`
        case 3:  return `Applying design to your questions`
        default: return `Almost there — adding the final touches`
      }
    }
    switch (stage) {
      case 1:  return `Writing questions on <em>${this._topic(this._theme)}</em> for ${this._audience(this._age)}`
      case 2:  return `Choosing formats that keep <em>${this._audience(this._age)}</em> engaged`
      case 3:  return `Tuning your <em>${this._topic(this._theme)}</em> Verto for ${this._audience(this._age)}`
      default: return `Almost there — adding the final touches`
    }
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

  // Accepts either the form (finds its submit button) or a submit button directly.
  _shakeSubmit(el) {
    const btn = el?.matches?.('input[type="submit"], button[type="submit"]')
      ? el
      : el?.querySelector?.('input[type="submit"], button[type="submit"]')
    if (!btn) return
    btn.classList.remove("is-shaking")
    void btn.offsetWidth // restart the CSS animation
    btn.classList.add("is-shaking")
    btn.addEventListener("animationend", () => btn.classList.remove("is-shaking"), { once: true })
  }
}
