import { Controller } from "@hotwired/stimulus"

// Paints in the imagery an IMPORT's FinishVertoSetupJob is filling in behind
// the creator, while they are already in the editor.
//
// ── Why this exists at all ──────────────────────────────────────────────────
// The wizard populates imagery before its wait screen releases, so its editor
// opens with pictures already in the deck. An import doesn't: the creator has
// already waited through the upload and the review screen, so they are handed
// straight to the editor and the job runs behind them. That was the right call
// and it stays — but it left the editor with no idea the job existed. Nothing
// on screen said imagery was coming, nothing refreshed when it landed, and the
// creator's own autosave actively destroyed it (see below). "Images didn't
// generate when they created a Verto with PDF questions" was all three.
//
// ── Why it writes datasets and not just pixels ──────────────────────────────
// This is the load-bearing part. survey_editor_controller#serialize() rebuilds
// the whole deck from the DOM — it reads `data-card-image` and only emits
// `image` when that attribute is non-empty. It never looks at the rendered
// `.split-left`. So a repaint that only changed pixels would look correct and
// still be wiped by the next autosave, and a repaint that only changed the
// datasets would survive the save and show nothing. It has to be both, and
// they have to move together.
//
// Which is why the apply step is not reimplemented here: it calls the media
// picker's own writers. _setCardImage/_setCardVideo/_setTapOptionImage already
// do exactly this job when a creator picks a photo by hand — datasets and
// `.split-left` in one step, in the order the photo-XOR-video-XOR-animation
// rule requires. Calling them means a populated card and a hand-picked card
// cannot diverge; copying them would mean they eventually do.
export default class extends Controller {
  static values = { url: String, pending: Boolean }

  static INTERVAL_MS = 2000
  // ~3 minutes. The server-side window (Survey::SETUP_STALE_AFTER) is longer,
  // but that one guards data; this one only guards a tab from polling forever
  // if something upstream never clears the flag.
  static MAX_TICKS = 90

  connect() {
    this._stopped = false
    this._ticks   = 0
    if (!this.pendingValue || !this.hasUrlValue || !this.urlValue) return
    this._announce("running")
    this._schedule()
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
      // A dropped poll is not worth telling anyone about — the next one covers
      // it, and the job is unaffected either way.
      if (this._ticks < this.constructor.MAX_TICKS) this._schedule()
      return
    }

    this._apply(data)

    if (data.pending && this._ticks < this.constructor.MAX_TICKS) {
      this._schedule()
    } else {
      this._announce("done")
    }
  }

  _apply(data) {
    if (data.background_css) this.element.setAttribute("style", data.background_css)

    const picker = this.application.getControllerForElementAndIdentifier(this.element, "media-picker")
    Array.from(data.cards || []).forEach(entry => this._applyCard(entry, picker))
  }

  _applyCard(entry, picker) {
    const card = this.element.querySelector(
      `[data-survey-editor-target='card'][data-card-cid='${CSS.escape(entry.cid || "")}']`
    )
    if (!card) return
    // Fill only, never overwrite. The server guarantees this too
    // (AssetPopulator's fill_only), but the creator may have picked a photo in
    // the seconds since the payload was built and only the client knows that.
    if (card.dataset.cardImage || card.dataset.cardVideo || card.dataset.cardLottie) return
    // Rebuilding `.split-left` under someone's cursor can disturb a selection.
    // Skip this card and take it on the next tick.
    if (card.contains(document.activeElement)) return

    if (picker) {
      if (entry.video) {
        picker._setCardVideo(card, entry.video, entry.video_poster || "",
                             entry.image_credit || "", entry.image_credit_url || "")
      } else if (entry.image) {
        picker._setCardImage(card, entry.image, entry.image_credit || "", entry.image_credit_url || "")
      }
      Array.from(entry.option_images || []).forEach((url, i) => {
        if (url) picker._setTapOptionImage(card, i, url)
      })
    }

    if (entry.range_theme) this._setRangeTheme(card, entry.range_theme)
    // Nothing renders `subject`, which is exactly why it is easy to forget —
    // and serialize() emits it, so without this line the first autosave after
    // setup would strip the work CardSubjectExtractor paid Claude for and every
    // later Shuffle would lose its anchor.
    if (entry.subject) card.dataset.cardSubject = entry.subject
  }

  // Mirrors survey_editor#setRangeTheme's body minus its markDirty — see the
  // note in _announce about why nothing here marks the deck dirty.
  _setRangeTheme(card, theme) {
    card.dataset.cardRangeTheme = theme
    const editor = this.application.getControllerForElementAndIdentifier(this.element, "survey-editor")
    const urls   = editor?._rangeThemeUrls?.[theme]
    const wrap   = card.querySelector(".nps-lottie")
    if (wrap && urls) wrap.dataset.lottiePlayerUrlsValue = JSON.stringify(urls)
  }

  // A repaint is not a creator edit, so nothing here calls markDirty(): that
  // would schedule a PATCH of a deck nobody touched and re-enter the very race
  // this controller exists to close. The datasets are written so that the next
  // GENUINE edit carries the imagery — no save of our own is needed or wanted.
  _announce(state) {
    this.dispatch("progress", { detail: { state } })
  }
}
