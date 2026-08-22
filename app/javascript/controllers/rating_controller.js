import { Controller } from "@hotwired/stimulus"
import { haptic } from "lib/haptics"

export default class extends Controller {
  static targets = ["star", "midLabel", "endLabel"]
  static values  = { index: { type: Number, default: -1 } }

  connect() { this._render() }

  pick(event) {
    if (event.target.isContentEditable) return
    event.stopPropagation()
    this.indexValue = parseInt(event.currentTarget.dataset.ratingIndex, 10)
    this._render()
    haptic()
    this._burst(event.currentTarget)
    this.dispatch("pick", { detail: { index: this.indexValue } })
  }

  // Stars are radios outside the editor (P2-4), so Enter/Space select and the
  // arrows move between them — the pointer was previously the only way in.
  pickOnKey(event) {
    const activate = [ "Enter", " ", "Spacebar" ].includes(event.key)
    const forward  = [ "ArrowRight", "ArrowDown" ].includes(event.key)
    const back     = [ "ArrowLeft", "ArrowUp" ].includes(event.key)
    if (!activate && !forward && !back) return
    if (event.target.isContentEditable) return
    event.preventDefault()

    if (activate) return this.pick(event)

    const from = this.indexValue < 0 ? (forward ? -1 : this.starTargets.length) : this.indexValue
    const next = Math.max(0, Math.min(this.starTargets.length - 1, from + (forward ? 1 : -1)))
    this.indexValue = next
    this._render()
    this.starTargets[next]?.focus()
    haptic()
    this.dispatch("pick", { detail: { index: next } })
  }

  hover(event) {
    this._highlight(parseInt(event.currentTarget.dataset.ratingIndex, 10))
  }

  unhover() { this._highlight(this.indexValue) }

  _render() {
    this._highlight(this.indexValue)
    // Announce which star is chosen. Guarded on the role so the editor, which
    // renders the same stars without radio semantics, isn't given a state.
    this.starTargets.forEach((star, i) => {
      if (star.hasAttribute("role")) star.setAttribute("aria-checked", i === this.indexValue ? "true" : "false")
    })
  }

  // Show the caption belonging to the star being pointed at or chosen. The two
  // end captions are always up, so the middles only need to appear for the
  // stars in between — which is what was asked for: "maybe you tap star 2, 3 or
  // 4, and the text appears in the middle". `upTo` of -1 (nothing chosen, and
  // not hovering) clears it.
  _showMidLabel(index) {
    if (!this.hasMidLabelTarget) return
    this.midLabelTargets.forEach((el) => {
      el.classList.toggle("is-shown", Number(el.dataset.ratingIndex) === index)
    })
  }

  _highlight(upTo) {
    this._showMidLabel(upTo)
    this.starTargets.forEach((star, i) => {
      const active = i <= upTo
      star.classList.toggle("active", active)
      // Themed icon glyphs ride on each star (star kind swaps ★/☆; emoji
      // kinds keep the same glyph and let CSS dim the inactive ones).
      const on  = star.dataset.ratingOn  || "★"
      const off = star.dataset.ratingOff || "☆"
      star.textContent = active ? on : off
    })
  }

  // Tidy up a burst still in flight when the card goes away, so a navigation
  // mid-animation cannot leave a layer parented to the overlay forever.
  disconnect() {
    this._burstLayer?.remove()
    this._burstLayer = null
    clearTimeout(this._burstTimer)
  }

  // Confetti: when a rating is picked the tapped icon "explodes" into a burst
  // of little copies of itself that fly out and fade. The pieces use the
  // card's own icon (★ or the themed emoji), so it always matches the Verto.
  //
  // THE LAYER LIVES OUTSIDE THE ANSWER SCROLLER, and that is the whole reason
  // this is more than four lines. The pieces fly 38–90px outward plus 22px of
  // gravity — up to ~112px from the star, plus their own half-height — and any
  // element that reaches past a scroll container counts toward what that
  // container can scroll. Parented inside the card, tapping a star therefore
  // grew the answer scroller and a scrollbar appeared for the two-thirds of a
  // second the animation ran, then vanished. That is the owner's "weird
  // scrollbar appear right hand side when you tap a star", and it is the
  // celebration, not the card's height.
  //
  // `overflow: clip` on .rating-stars was the first attempt and it is not
  // enough: it only removes what lands BEYOND the clip margin, so the fix held
  // for a ★ (whose pieces mostly stay inside 80px) and failed on every single
  // tap of a themed emoji card, whose glyphs render taller and clear it every
  // time. Measured, 8 taps per configuration: star 1/8 at up to 10px, emoji
  // 8/8 at 17–47px.
  //
  // So the layer is hosted on the overlay — a sibling of the scrolling
  // .preview-body, not a descendant — and positioned in viewport coordinates.
  // A fixed-position element outside the scroller cannot contribute to it, for
  // any glyph, at any size. Falls back to <body> in the editor feed, which has
  // no overlay.
  _burst(originStar) {
    if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return
    if (!originStar) return

    originStar.classList.remove("pop")
    void originStar.offsetWidth // restart the pop animation if re-tapped
    originStar.classList.add("pop")

    const glyph = originStar.dataset.ratingOn || originStar.textContent || "★"
    const sRect = originStar.getBoundingClientRect()

    // Anchor the layer on the tapped star, in viewport space, and give the
    // pieces a common origin of 0,0 within it — so the layer itself is a
    // zero-size point and only the pieces' own transforms move anything.
    const layer = document.createElement("div")
    layer.className = "rating-burst"
    layer.style.left = `${sRect.left + sRect.width / 2}px`
    layer.style.top  = `${sRect.top + sRect.height / 2}px`

    const pieces = 14
    for (let i = 0; i < pieces; i++) {
      const angle = (Math.PI * 2 * i) / pieces + (Math.random() - 0.5) * 0.6
      const dist  = 38 + Math.random() * 52
      const p = document.createElement("span")
      p.className = "rating-burst-piece"
      p.textContent = glyph
      // Fly radially, then a touch of gravity pulls the end point down.
      p.style.setProperty("--tx", `${Math.cos(angle) * dist}px`)
      p.style.setProperty("--ty", `${Math.sin(angle) * dist + 22}px`)
      p.style.setProperty("--r",  `${(Math.random() * 2 - 1) * 240}deg`)
      p.style.setProperty("--s",  (0.5 + Math.random() * 0.6).toFixed(2))
      p.style.setProperty("--d",  `${560 + Math.random() * 360}ms`)
      layer.appendChild(p)
    }

    this._burstLayer?.remove()
    clearTimeout(this._burstTimer)
    this._burstLayer = layer
    const host = this.element.closest(".preview-overlay") || document.body
    host.appendChild(layer)
    this._burstTimer = setTimeout(() => {
      layer.remove()
      if (this._burstLayer === layer) this._burstLayer = null
    }, 1100)
  }
}
