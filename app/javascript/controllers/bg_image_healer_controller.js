import { Controller } from "@hotwired/stimulus"

// A card's header photo and a tap-card statement's photo are both painted
// via a server-rendered CSS background-image/background, not an <img> tag —
// so a request that fails has nothing to retry and nowhere to show a broken
// icon; the panel just stays blank. That's routine during the few seconds a
// deploy's stop/start swap takes (render.yaml pins this app to a single
// instance for its persistent disk, so deploys aren't zero-downtime): a
// request landing in that window fails once, and nothing ever asks again.
// Reported 19 Aug as "the push wiped my assets" — the data was untouched
// (a hard refresh brought it straight back), just the one paint that lost
// its race with the restart.
//
// Preloads the SAME url the element already points at. The ordinary case —
// the background already loaded fine — costs one browser-cache-served
// request and repaints nothing. A failure retries with backoff before
// giving up, so a transient blip self-heals within the same visit instead
// of needing a manual hard refresh.
const RETRY_DELAYS_MS = [ 600, 1500, 3000 ]

export default class extends Controller {
  connect() {
    const url = this._url()
    if (url) this._heal(url, 0)
  }

  // Reads back whatever the server already set — works whether it arrived
  // via the `background-image` longhand or the `background` shorthand
  // (CSS OM populates the longhand either way), and returns null for a
  // card with no image (a plain colour/gradient), which is not this
  // controller's concern.
  _url() {
    const match = /^url\((['"]?)(.*)\1\)$/.exec(this.element.style.backgroundImage || "")
    return match ? match[2] : null
  }

  _heal(url, attempt) {
    const img = new Image()
    img.onload = () => {
      // The first, near-instant load is the ordinary case and is already
      // painted — only a RETRY needs the style re-applied to force a repaint,
      // since setting the same url again is otherwise a no-op.
      if (attempt > 0) this.element.style.backgroundImage = `url('${url}')`
    }
    img.onerror = () => {
      if (attempt >= RETRY_DELAYS_MS.length) return
      setTimeout(() => this._heal(url, attempt + 1), RETRY_DELAYS_MS[attempt])
    }
    img.src = url
  }
}
