import { Controller } from "@hotwired/stimulus"
import lottie from "lottie-web"

// Modal that lets an editor swap a card's animation — the animation equivalent
// of the media picker for images. Mirrors media-picker's open/close (the
// backdrop `hidden` toggle) and applies the pick by driving the card's hidden
// <select> (survey-editor#setRangeTheme / #setNpsShape does the live swap +
// autosave), so the visual picker and any keyboard/SR use share ONE apply path.
//
// Two panes, because two card types have an animation and they are different
// things:
//   open()       Range — the reaction CHARACTER, a Lottie set per theme. URLs
//                come from the #range-theme-picker JSON blob already emitted in
//                the editor head, and each tile mounts a small looping preview.
//   openShapes() NPS — the liquid CONTAINER. Its tiles are server-rendered SVG
//                (nps_shape_preview), so there is nothing to mount and nothing
//                to tear down.
export default class extends Controller {
  static targets = ["backdrop", "option", "preview", "lottiePane", "shapePane", "shapeOption"]

  connect() {
    this._activeCard = null
    this._mounted = false
    this._instances = []
    this._escListener = (e) => { if (e.key === "Escape") this.close() }
  }

  disconnect() {
    this._destroyPreviews()
    document.removeEventListener("keydown", this._escListener)
  }

  // Opened by the "Change animation" CTA on a Range card's left panel.
  open(event) {
    if (!this._activate(event, "lottie")) return
    this._mountPreviews()
    this._highlightCurrent()
    this._instances.forEach(i => i.play())
  }

  // …and by the same CTA on an NPS card's, where the animation is the vessel.
  openShapes(event) {
    if (!this._activate(event, "shape")) return
    this._highlightCurrentShape()
  }

  // The half both entry points share: find the card the CTA belongs to, show
  // the pane that answers for its type, and open.
  _activate(event, mode) {
    event?.preventDefault()
    const trigger = event?.currentTarget
    const card = trigger?.closest("[data-survey-editor-target='card']")
              || trigger?.closest(".survey-card-wrap")
    if (!card) return false
    this._activeCard = card
    if (this.hasLottiePaneTarget) this.lottiePaneTarget.hidden = mode !== "lottie"
    if (this.hasShapePaneTarget)  this.shapePaneTarget.hidden  = mode !== "shape"
    this.backdropTarget.hidden = false
    document.addEventListener("keydown", this._escListener)
    return true
  }

  close() {
    this.backdropTarget.hidden = true
    this._activeCard = null
    // Pause (don't destroy) so re-opening is instant; paused rAF frees the CPU.
    this._instances.forEach(i => i.pause())
    document.removeEventListener("keydown", this._escListener)
  }

  backdropClick(event) {
    if (event.target === this.backdropTarget) this.close()
  }

  // Apply a chosen animation to the active card. Drives the card's hidden
  // <select> so survey-editor#setRangeTheme performs the live swap + autosave —
  // the exact same path the inline picker used, so behaviour can't drift.
  pick(event) {
    this._apply(event, ".range-theme-select", this.optionTargets)
  }

  // Same contract for the NPS vessel — a different <select> and a different
  // survey-editor action behind it, nothing else.
  pickShape(event) {
    this._apply(event, ".nps-shape-select", this.shapeOptionTargets)
  }

  _apply(event, selector, options) {
    const slug = event.currentTarget?.dataset.slug
    if (!slug || !this._activeCard) { this.close(); return }
    const select = this._activeCard.querySelector(selector)
    if (select) {
      select.value = slug
      select.dispatchEvent(new Event("change", { bubbles: true }))
    }
    this._mark(options, slug)
    this.close()
  }

  // ── previews ───────────────────────────────────────────
  // Mount one small looping Lottie per option (the neutral middle frame is the
  // representative pose). Done once, lazily, on first open. A load failure just
  // leaves that tile label-only rather than breaking the picker.
  _mountPreviews() {
    if (this._mounted) return
    const urls = this._themeUrls
    this.previewTargets.forEach(el => {
      const set = urls[el.dataset.slug]
      const path = set && (set[Math.floor(set.length / 2)] || set[0])
      if (!path) return
      try {
        this._instances.push(lottie.loadAnimation({
          container: el, renderer: "svg", loop: true, autoplay: false, path
        }))
      } catch (_) { /* label-only tile */ }
    })
    this._mounted = true
  }

  _destroyPreviews() {
    this._instances.forEach(i => { try { i.destroy() } catch (_) { /* noop */ } })
    this._instances = []
    this._mounted = false
  }

  _highlightCurrent() {
    const cur = this._activeCard?.querySelector(".range-theme-select")?.value
             || this._activeCard?.dataset.cardRangeTheme
    this._mark(this.optionTargets, cur)
  }

  // No dataset fallback here: an NPS card only carries data-card-nps-shape once
  // the creator has picked one, and before that the <select> is already parked
  // on the Verto-themed default the server chose (nps_shape_slug) — which is
  // the shape the card is actually drawing, so it is the one to tick.
  _highlightCurrentShape() {
    this._mark(this.shapeOptionTargets, this._activeCard?.querySelector(".nps-shape-select")?.value)
  }

  _mark(options, slug) {
    options.forEach(o =>
      o.setAttribute("aria-selected", o.dataset.slug === slug ? "true" : "false")
    )
  }

  // { slug: [5 asset URLs] } read once from the editor head's blob.
  get _themeUrls() {
    if (this.__urls) return this.__urls
    const map = {}
    try {
      const data = JSON.parse(document.getElementById("range-theme-picker")?.textContent || "{}")
      ;(data.themes || []).forEach(t => { map[t.slug] = t.urls })
    } catch (_) { /* leave empty */ }
    this.__urls = map
    return map
  }
}
