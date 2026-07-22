import { Controller } from "@hotwired/stimulus"

const COOKIE_NAME = "verto_cookie_consent"
const COOKIE_MAX_AGE = 60 * 60 * 24 * 365 // 1 year

// Cookie-consent banner shown on first visit, everywhere in the app
// (dashboard, auth pages, and the public /play/:token player). Necessary
// cookies are always on; Analytics (Microsoft Clarity) is opt-in and is only
// activated once accepted here — never before, and never unconditionally, so
// this is the single gate non-essential tracking must pass through. The
// choice is stored in a first-party cookie (not localStorage) so it's a
// plain, inspectable consent record, matching the shape %{necessary,
// analytics} the legacy player used.
export default class extends Controller {
  static targets = ["banner", "settings", "analyticsToggle"]
  static values = { clarityId: String }

  connect() {
    this._reopenHandler = this.reopen.bind(this)
    window.addEventListener("cookie-consent:reopen", this._reopenHandler)

    const consent = this._readConsent()
    if (!consent) {
      this.element.classList.remove("hidden")
      return
    }
    if (consent.analytics) this._activateAnalytics()
  }

  disconnect() {
    window.removeEventListener("cookie-consent:reopen", this._reopenHandler)
  }

  // Triggered from anywhere on the page (the footer's "Cookie settings" link,
  // the Cookie Policy page) via a plain window event, so callers don't need
  // to be nested inside this controller's element — there's only ever one
  // banner instance, mounted once per layout.
  reopen() {
    this.settingsTarget.classList.add("hidden")
    this.bannerTarget.classList.remove("hidden")
    this.element.classList.remove("hidden")
  }

  acceptAll() {
    this._save({ necessary: true, analytics: true })
    this._activateAnalytics()
    this._hide()
  }

  rejectAll() {
    this._save({ necessary: true, analytics: false })
    this._hide()
  }

  openSettings() {
    if (this.hasAnalyticsToggleTarget) {
      const consent = this._readConsent()
      this.analyticsToggleTarget.checked = consent ? !!consent.analytics : false
    }
    this.bannerTarget.classList.add("hidden")
    this.settingsTarget.classList.remove("hidden")
  }

  backToBanner() {
    this.settingsTarget.classList.add("hidden")
    this.bannerTarget.classList.remove("hidden")
  }

  savePreferences() {
    const analytics = this.hasAnalyticsToggleTarget ? this.analyticsToggleTarget.checked : false
    this._save({ necessary: true, analytics })
    if (analytics) this._activateAnalytics()
    this._hide()
  }

  _hide() {
    this.element.classList.add("hidden")
  }

  _save(consent) {
    const secure = window.location.protocol === "https:" ? "; Secure" : ""
    document.cookie =
      `${COOKIE_NAME}=${encodeURIComponent(JSON.stringify(consent))}; path=/; max-age=${COOKIE_MAX_AGE}; SameSite=Lax${secure}`
  }

  _readConsent() {
    const match = document.cookie.match(new RegExp(`(?:^|; )${COOKIE_NAME}=([^;]*)`))
    if (!match) return null
    try {
      const parsed = JSON.parse(decodeURIComponent(match[1]))
      return parsed && typeof parsed === "object" ? parsed : null
    } catch (_) {
      return null
    }
  }

  // Guarded on a window flag (not just a local one) — Turbo swaps <body> on
  // each visit, so this controller reconnects on every navigation, but the
  // injected <script> tag and window/JS realm persist across Turbo visits.
  // Without the guard, a returning-with-consent visitor would get Clarity's
  // loader re-injected (and re-run) on every single page change.
  _activateAnalytics() {
    if (window.__vertoClarityLoaded) return
    window.__vertoClarityLoaded = true

    const id = this.clarityIdValue
    if (!id) return
    ;(function (c, l, a, r, i, t, y) {
      c[a] = c[a] || function () { (c[a].q = c[a].q || []).push(arguments) }
      t = l.createElement(r); t.async = 1; t.src = "https://www.clarity.ms/tag/" + i
      y = l.getElementsByTagName(r)[0]; y.parentNode.insertBefore(t, y)
    })(window, document, "clarity", "script", id)
  }
}
