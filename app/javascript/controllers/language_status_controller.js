import { Controller } from "@hotwired/stimulus"

// Keeps the languages rail honest while a translation is running behind it.
//
// The screen is a plain server render, so a language finishing changed nothing
// on the page — the only way to find out was to guess when to press reload.
// "Give it a minute, then reload" is just the spinner-that-never-resolves
// wearing a hint: it still makes somebody do the waiting, and it still leaves
// them unable to tell "not yet" from "not ever".
//
// Polls only while the server says something is outstanding, and stops the
// moment it isn't — so a page left open on a finished Verto costs nothing. The
// server reports display_status, which means a run abandoned by a dead worker
// ends the poll instead of keeping a tab asking for ever
// (SurveyTranslation#stale?).
//
// Enhancement only. With no JavaScript the rail is exactly what it was: correct
// at render time, refreshed by reloading — which is the same deal the rest of
// this screen offers, every action being a plain form POST.
export default class extends Controller {
  static values = { url: String, working: Boolean }
  static targets = ["rail"]

  static INTERVAL_MS = 4000
  // ~6 minutes of asking. The server's own staleness window is longer and is
  // what decides whether a run is dead; this only stops one tab pestering it
  // if something upstream never resolves.
  static MAX_TICKS = 90

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
    this._timer = setTimeout(() => this._tick(), this.constructor.INTERVAL_MS)
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

    if (data.working && this._ticks < this.constructor.MAX_TICKS) {
      this._paint(data.languages || [])
      this._schedule()
      return
    }

    // Nothing outstanding. The board below the rail is now out of date too —
    // it was rendered before these translations existed — so the honest move
    // is a full reload rather than repainting the rail over a stale board and
    // leaving the two disagreeing.
    window.location.reload()
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
