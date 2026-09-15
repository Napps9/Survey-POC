import { Controller } from "@hotwired/stimulus"

// Keeps the languages rail honest while a translation is running behind it.
//
// The screen is a plain server render, so a language finishing changed nothing
// on the page — the only way to find out was to guess when to press reload.
// "Give it a minute, then reload" is just the spinner-that-never-resolves
// wearing a hint: it still makes somebody do the waiting, and it still leaves
// them unable to tell "not yet" from "not ever".
//
// Polls only while something is still expected to land, and stops when it
// isn't — so a page left open on a finished Verto costs nothing. What counts
// as outstanding is read off the DECK (LanguageCheckLines.outstanding?), which
// includes a language with no translation run recorded against it at all: most
// of the ways a Verto gets translated never write one, and those were exactly
// the pages that sat on "Not translated yet" until somebody reloaded.
//
// The reload is driven by a STATE SIGNATURE, not by the absence of work. A
// language nobody has started reports nothing outstanding for as long as it
// stays that way, so reloading on that answer would reload this page every few
// seconds for ever. A run abandoned by a dead worker still ends the poll —
// display_status decides that, server-side (SurveyTranslation#stale?).
//
// Enhancement only. With no JavaScript the rail is exactly what it was: correct
// at render time, refreshed by reloading — which is the same deal the rest of
// this screen offers, every action being a plain form POST.
export default class extends Controller {
  static values = { url: String, working: Boolean, signature: String }
  static targets = ["rail"]

  static INTERVAL_MS = 4000
  // Most translations land in the first minute; after that, asking every four
  // seconds is just noise. Backing off buys a longer wall-clock window for
  // fewer requests than the flat 90 ticks this replaces (45 against 90), which
  // matters now that the page watches more often than it used to.
  static SLOW_AFTER = 15
  static SLOW_MS = 12000
  // ~7 minutes of asking. The server's own staleness window is longer and is
  // what decides whether a run is dead; this only stops one tab pestering it
  // if something upstream never resolves.
  static MAX_TICKS = 45

  connect() {
    this._stopped = false
    this._ticks = 0
    if (this.workingValue && this.hasUrlValue) this._schedule()
  }

  disconnect() {
    this._stopped = true
    clearTimeout(this._timer)
  }

  _schedule() {
    clearTimeout(this._timer)
    const ms = this._ticks >= this.constructor.SLOW_AFTER
      ? this.constructor.SLOW_MS
      : this.constructor.INTERVAL_MS
    this._timer = setTimeout(() => this._tick(), ms)
  }

  async _tick() {
    if (this._stopped) return
    this._ticks += 1

    let data
    try {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error(res.status)
      data = await res.json()
    } catch (_e) {
      // A dropped poll is nobody's problem — the next one covers it, and the
      // translation is unaffected either way.
      if (this._ticks < this.constructor.MAX_TICKS) this._schedule()
      return
    }

    // A language has CHANGED state since this page was drawn. The board below
    // the rail is out of date too — it was rendered before that translation
    // existed — so the honest move is a full reload rather than repainting the
    // rail over a stale board and leaving the two disagreeing.
    //
    // Reloading on "nothing outstanding" instead, which is what this did, is
    // only safe while the page is armed exclusively by live run rows. The page
    // now also watches a language that has no run row at all — the common case,
    // since most translation paths never write one — and for that language the
    // server reports nothing outstanding for as long as it stays untranslated.
    // Reloading on that answer is a page that reloads itself every four seconds
    // for ever, on the screen a creator is working in.
    if (data.signature && this.hasSignatureValue && data.signature !== this.signatureValue) {
      window.location.reload()
      return
    }

    this._paint(data.languages || [])

    if (data.working && this._ticks < this.constructor.MAX_TICKS) {
      this._schedule()
      return
    }

    // Nothing outstanding and nothing changed. Stop, quietly: the rail is
    // already showing what is true, and a language nobody has started is a
    // state this screen reports rather than an event it waits for.
  }

  // Live counts while we wait, so a long deck visibly progresses instead of
  // sitting on one word. Text only: anything that changes which CONTROLS a row
  // offers is the server's to decide, and this would be guessing at it.
  _paint(languages) {
    languages.forEach(lang => {
      const row = this.element.querySelector(`[data-language-row='${CSS.escape(lang.locale)}']`)
      if (!row) return
      const status = row.querySelector("[data-language-count]")
      if (status && lang.total > 0 && lang.state !== "primary" && lang.state !== "done") {
        status.textContent = `${lang.translated}/${lang.total}`
      }
    })
  }
}
