import { Controller } from "@hotwired/stimulus"

// "Share with others" on a Verto in the account.
//
// Three rungs, best first: the OS share sheet where the browser has one (which
// is where this matters — a respondent sharing a Verto is on a phone, sending
// it to one person), the clipboard where it does not, and if neither is
// available the click is left alone and the link opens the Verto, which is
// still a URL they can copy out of the address bar. Nothing here is
// load-bearing: the element is an ordinary <a href> to the play page.
//
// The "copied" label arrives as a value rather than a JS string, because
// window.I18N carries `js:` plus one curated slice and a respondent-account
// string is in neither — it would render as a raw dotted key. Rails translates
// it into the attribute instead.
const REVERT_AFTER = 2000

export default class extends Controller {
  static values = { title: String, copied: String }

  async share(event) {
    const url = this.element.href
    if (!url) return

    if (navigator.share) {
      event.preventDefault()
      try {
        await navigator.share({ title: this.titleValue, url: url })
      } catch (error) {
        // A dismissed share sheet is the ordinary case, not a failure — the
        // respondent changed their mind. Anything else falls through to the
        // clipboard rather than leaving the tap with nothing to show for it.
        if (error && error.name === "AbortError") return
        this.copy(url)
      }
      return
    }

    if (navigator.clipboard) {
      event.preventDefault()
      this.copy(url)
    }
    // No share, no clipboard: let the link do what links do.
  }

  async copy(url) {
    try {
      await navigator.clipboard.writeText(url)
      this.confirm()
    } catch {
      // Clipboard refused (an insecure origin, or permission denied). Say
      // nothing rather than claiming a copy that did not happen.
    }
  }

  confirm() {
    if (this.reverting) clearTimeout(this.reverting)
    this.original ??= this.element.textContent
    this.element.textContent = this.copiedValue || this.original
    this.reverting = setTimeout(() => {
      this.element.textContent = this.original
      this.reverting = null
    }, REVERT_AFTER)
  }

  disconnect() {
    if (this.reverting) clearTimeout(this.reverting)
  }
}
