import { Controller } from "@hotwired/stimulus"

// Verto slider: track with N dots, draggable thumb. Snaps to the nearest
// step on release. Horizontal by default; axisValue "vertical" flips the
// drag math and positions the thumb via `bottom` instead of `left` — dots
// are positioned once at render time by the server/JS builder (see
// _card_component.html.erb / sliderHtml in type_panel_controller.js), so
// only the thumb needs runtime axis awareness.
//
// It also drives the left-panel reaction animation on Range cards: each step
// change dispatches `verto:scaleValue` with a 1–5 value (the slider's 3–5
// steps mapped proportionally onto the 5 animation frames), which the
// lottie-player controller listens for.
const REACTION_FRAMES = 5

// The neutral, expressionless middle frame — where the character rests before
// the respondent has said anything (mirrors NpsHelper::NPS_NEUTRAL_FRAME).
const REACTION_NEUTRAL = Math.ceil(REACTION_FRAMES / 2)

// The most lines one stop's label may take before the scale stops being a
// scale. Two is the shape the row was drawn for ("Somewhat / ready"); three is
// a paragraph standing under a dot.
const LABEL_MAX_LINES = 2

export default class extends Controller {
  static targets = ["track", "thumb", "dot", "label", "labels", "readout"]
  static values  = {
    steps: Number,
    index: { type: Number, default: 0 },
    axis:  { type: String, default: "horizontal" }
  }

  connect() {
    this._onMove = this.onMove.bind(this)
    this._onUp   = this.onUp.bind(this)
    this.indexValue = Math.floor((this.stepsValue - 1) / 2)
    this.render()
    this._watchWidth()
    // Open on the NEUTRAL frame explicitly rather than deriving it from the
    // step count: a legacy even-count scale (a published 4-point Verto, which
    // Survey#enforce_range_scale deliberately leaves alone) maps its centre
    // index to an off-centre frame, so the character would greet the
    // respondent already leaning one way.
    this._dispatchScaleValue(REACTION_NEUTRAL)
  }

  disconnect() {
    this._widthObserver?.disconnect()
    this._widthObserver = null
  }

  // ── Fitting the scale to the width it actually gets ──────────────────────
  //
  // Which layout a range card can afford is a question about the width the
  // panel ends up handing it, and it was being answered from the card's text:
  // NpsHelper#resolved_slider_axis counts characters on the server and picks an
  // axis from them. A character count cannot know the panel's width, the text
  // size the respondent chose, or which of the 19 locales the words are in — so
  // a scale that passes the count still prints five columns of broken words,
  // which is the report this is written against ("Somewhat / ready" stacked
  // under a dot that isn't its own).
  //
  // So: the same buy-back shape _fitCard uses for the card's pictures, applied
  // to the scale's own words. Start from what the card wants and keep it only
  // while it can be READ. Two rungs:
  //
  //   1. Every stop labelled under its own dot. What the card wants.
  //   2. The two ENDS only, with the chosen stop named in full above the track
  //      (.slider-readout). The scale still reads end to end, the answer is
  //      stated in words, the dots are all still there to drag between — and
  //      nothing is broken mid-word to make it fit.
  //
  // There is no rung that shrinks the type: player_type_floor_test exists
  // because the answer is the last thing on a card that may get smaller.
  //
  // The decision is a pure function of the track's width and the label texts —
  // never of the state it is about to set — so the ResizeObserver that drives
  // it cannot chase its own tail: condensing changes the row's HEIGHT, which
  // re-runs this, which measures the same width and decides the same thing.
  _watchWidth() {
    this._fitLabels()
    if (typeof ResizeObserver === "undefined") return
    // The player keeps every card in the DOM at display:none until its turn,
    // so the first real width this card ever has arrives here, not at connect.
    this._widthObserver = new ResizeObserver(() => this._fitLabels())
    this._widthObserver.observe(this.element)
  }

  // The stop labels, from the row rather than from `label` targets: the
  // editor's own renderer (type_panel's sliderHtml) builds the same row without
  // them, and this has to see the same five words there as here.
  _scaleLabels() {
    if (!this.hasLabelsTarget) return []
    return Array.from(this.labelsTarget.querySelectorAll(".slider-label-text"))
  }

  _fitLabels() {
    if (!this.hasLabelsTarget || this.axisValue === "vertical") return
    const labels = this._scaleLabels()
    // The editor shows every stop whatever it costs — they are the card's
    // content there, and a creator cannot edit a label that isn't rendered.
    if (labels.length < 3 || labels.some(el => el.isContentEditable)) return

    // The row, not the track: the labels divide the full panel width into n
    // equal columns and the TRACK is the inset one (see .slider-track-wrap).
    // Measured on the row's border box, so the answer doesn't change when the
    // condensed rung adds the row's own inset padding.
    const width = this.labelsTarget.getBoundingClientRect().width
    if (width <= 0) return   // not on screen yet — the observer will call back

    const condensed = !this._stopsFit(labels, width / labels.length)
    this.labelsTarget.classList.toggle("is-condensed", condensed)
    if (this.hasReadoutTarget) this.readoutTarget.hidden = !condensed
    this._renderReadout()
  }

  // Every stop's label in the column its own dot gives it — one nth of the row,
  // ends included, which is what the track's inset buys them.
  _stopsFit(labels, column) {
    const measure = this._textMeasurer(labels[0])
    try {
      return labels.every(el =>
        this._lineCount(el.textContent.trim(), column, measure) <= LABEL_MAX_LINES)
    } finally {
      measure.done()
    }
  }

  // How many lines this label takes in a column that wide — the greedy fill the
  // browser itself does, run on the words rather than on the whole string.
  // "Way too much" is 88px of text in a 66px column, which the arithmetic reads
  // as a comfortable two lines and the browser breaks into three: "Way" / "too"
  // / "much", because "Way too" is already 68px. The estimate is the one that's
  // wrong there, and it's the estimate a respondent doesn't see.
  //
  // Infinity for a word wider than its own column: that is a word broken down
  // the middle — "disag / ree" — which no number of lines makes readable. It is
  // also the pathology the 17-character label cap was aimed at and can't
  // actually prevent, since 13 of the 19 locales ship a preset agreement label
  // longer than that.
  _lineCount(text, column, measure) {
    const words = text.split(/\s+/).filter(Boolean)
    if (!words.length) return 0

    let lines = 1
    let line  = ""
    for (const word of words) {
      if (measure(word) > column) return Infinity
      const candidate = line ? `${line} ${word}` : word
      if (measure(candidate) <= column) {
        line = candidate
      } else {
        lines += 1
        line = word
      }
    }
    return lines
  }

  // One off-layout probe wearing the labels' own type, so a measurement costs a
  // single insertion however many stops there are. Absolutely positioned, so it
  // never changes the size of the element the observer is watching, and gone
  // again before anything can paint or serialize — the editor rebuilds a range
  // card's options from `.slider-label-text` nodes, so the probe must never be
  // one, and must never outlive the measurement.
  _textMeasurer(ref) {
    const style = getComputedStyle(ref)
    const probe = document.createElement("span")
    probe.setAttribute("aria-hidden", "true")
    Object.assign(probe.style, {
      position: "absolute", top: "0", left: "0",
      visibility: "hidden", pointerEvents: "none", whiteSpace: "nowrap",
      fontFamily: style.fontFamily, fontSize: style.fontSize,
      fontWeight: style.fontWeight, fontStyle: style.fontStyle,
      letterSpacing: style.letterSpacing, textTransform: style.textTransform
    })
    this.element.appendChild(probe)

    const measure = (text) => {
      probe.textContent = text
      return probe.getBoundingClientRect().width
    }
    measure.done = () => probe.remove()
    return measure
  }

  _renderReadout() {
    if (!this.hasReadoutTarget || this.readoutTarget.hidden) return
    const label = this._scaleLabels()[this.indexValue]
    this.readoutTarget.textContent = label ? label.textContent.trim() : ""
  }

  // Arrow keys step the slider, mirroring nps_slider_controller#key (P2-4).
  // Without this the range card is drag-only — pointerdown is the sole way to
  // answer it, which locks out anyone not using a pointer.
  key(event) {
    const up   = [ "ArrowUp", "ArrowRight" ].includes(event.key)
    const down = [ "ArrowDown", "ArrowLeft" ].includes(event.key)
    if (!up && !down) return
    if (event.target.isContentEditable) return
    event.preventDefault()

    const n    = Math.max(2, this.stepsValue)
    const next = Math.max(0, Math.min(n - 1, this.indexValue + (up ? 1 : -1)))
    if (next === this.indexValue) return

    this.indexValue = next
    this.render()
    // No argument: _dispatchScaleValue derives the reaction frame from
    // indexValue, exactly as the drag path does.
    this._dispatchScaleValue()
  }

  // Tapping a label jumps straight to that step — with five 16px labels the
  // words are a far larger target than the dots they sit under. Player only:
  // the editor's labels are contenteditable and never carry this action.
  jump(event) {
    if (event.target.isContentEditable) return
    const idx = this.labelTargets.indexOf(event.currentTarget)
    if (idx < 0 || idx === this.indexValue) return
    this.indexValue = idx
    this.render()
    this._dispatchScaleValue()
    this.dispatch("settle", { detail: { index: this.indexValue } })
  }

  start(event) {
    if (event.target.isContentEditable) return
    event.preventDefault()
    event.stopPropagation() // don't also select/apply the type underneath
    this.dragging = true
    this.updateFromEvent(event)
    window.addEventListener("pointermove", this._onMove)
    window.addEventListener("pointerup",   this._onUp, { once: true })
  }

  onMove(event) { if (this.dragging) this.updateFromEvent(event) }
  onUp() {
    this.dragging = false
    window.removeEventListener("pointermove", this._onMove)
    this.dispatch("settle", { detail: { index: this.indexValue } })
  }

  updateFromEvent(event) {
    const rect = this.trackTarget.getBoundingClientRect()
    const raw  = this.axisValue === "vertical"
      ? (rect.bottom - event.clientY) / rect.height
      : (event.clientX - rect.left) / rect.width
    const ratio = Math.max(0, Math.min(1, raw))
    const n     = Math.max(2, this.stepsValue)
    const idx   = Math.round(ratio * (n - 1))
    if (idx !== this.indexValue) {
      this.indexValue = idx
      this.render()
      this._dispatchScaleValue()
    }
  }

  // Map the current step (0…n-1) onto a 1…5 frame and broadcast it for the
  // reaction animation. Dispatched from this slider's own element and left to
  // BUBBLE, so the lottie-player in the same .split-card picks it up and no
  // other card's does — the player and editor both hold every card in the DOM,
  // so a document-level event used to drag every character off neutral at once.
  _dispatchScaleValue(forced = null) {
    const n     = Math.max(2, this.stepsValue)
    const ratio = n > 1 ? this.indexValue / (n - 1) : 0
    const value = forced || Math.round(ratio * (REACTION_FRAMES - 1)) + 1
    this.element.dispatchEvent(
      new CustomEvent("verto:scaleValue", { detail: { value }, bubbles: true })
    )
  }

  render() {
    const n     = Math.max(2, this.stepsValue)
    const ratio = this.indexValue / (n - 1)
    const pct   = `${(ratio * 100).toFixed(2)}%`

    if (this.hasThumbTarget) {
      if (this.axisValue === "vertical") {
        this.thumbTarget.style.bottom = pct
        this.thumbTarget.style.left   = ""
      } else {
        this.thumbTarget.style.left   = pct
        this.thumbTarget.style.bottom = ""
      }
    }

    this.dotTargets.forEach((dot, i) =>
      dot.classList.toggle("active", i === this.indexValue)
    )

    // Same convention as the NPS labels: the chosen step's label lights up, so
    // the value reads without hunting for the active dot.
    this.labelTargets.forEach((label, i) =>
      label.classList.toggle("is-active", i === this.indexValue)
    )

    // On the condensed rung the middle labels aren't on the card to light up,
    // so the readout is the only thing that says where the thumb has landed.
    this._renderReadout()

    // Keep the announced value in step with the visible thumb. Only where the
    // role was applied — the editor renders the same markup without it.
    if (this.element.hasAttribute("role")) {
      this.element.setAttribute("aria-valuenow", String(this.indexValue))
      const label = this.labelTargets[this.indexValue]
      if (label) this.element.setAttribute("aria-valuetext", label.textContent.trim())
    }
  }
}
