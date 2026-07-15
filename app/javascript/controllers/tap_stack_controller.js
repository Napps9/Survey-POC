import { Controller } from "@hotwired/stimulus"

// Card-stack widget. Each card is a tap-stack#card target.
// Choice buttons carry data-tap-stack-direction="left|up|right".
// On click, the top card animates off-screen in that direction and the
// next card surfaces.
export default class extends Controller {
  static targets = ["card", "counter", "dots", "controls"]

  connect() {
    this.position = 0
    this.swipeResults = {}
    // In form mode the deck loses its swipe-off animation — the card just snaps
    // to the next one — so it reads as a plain question, not a game (the answer
    // is captured from the Yes/Unsure/No buttons either way).
    this.formsMode = !!this.element.closest(".forms-mode")
    this.layout()
  }

  pick(event) {
    if (event.target.isContentEditable) return
    event.stopPropagation() // don't also select/apply the type underneath
    const dir = event.currentTarget.dataset.tapStackDirection || "right"
    const top = this.cardTargets[this.position]
    if (!top) return
    // Key by the canonical (primary-language) label so tap results aggregate
    // across languages; fall back to the visible text for legacy markup.
    const label = top.dataset.canonical?.trim()
                  || top.querySelector("span")?.textContent?.trim()
                  || `Card ${this.position + 1}`
    this.swipeResults[label] = dir === "right" ? "yes" : dir === "up" ? "unsure" : "no"
    this.element.dataset.swipeResults = JSON.stringify(this.swipeResults)
    const tx = dir === "left" ? "-120%" : dir === "right" ? "120%" : "0"
    const ty = dir === "up"   ? "-120%" : "0"
    const rot = dir === "left" ? "-15deg" : dir === "right" ? "15deg" : "0deg"
    top.style.transition = this.formsMode ? "none" : "transform 350ms ease, opacity 350ms ease"
    top.style.transform  = `translate(${tx}, ${ty}) rotate(${rot})`
    top.style.opacity    = "0"
    this.position += 1
    setTimeout(() => this.layout(), 50)
    if (this.position >= this.cardTargets.length) {
      this.dispatch("complete", { detail: { results: this.swipeResults } })
    }
  }

  reset(event) {
    if (event) event.preventDefault()
    this.position = 0
    this.swipeResults = {}
    this.element.dataset.swipeResults = "{}"
    this.cardTargets.forEach((c) => {
      c.style.transition = "none"
      c.style.opacity    = ""
      c.style.transform  = ""
    })
    requestAnimationFrame(() => this.layout())
  }

  layout() {
    const total = this.cardTargets.length
    this._syncDots(total)
    // The response buttons sit in an overlay layered on top of the card stack
    // (see .rotate-card-controls), so they must out-rank every card's z-index
    // (top card = `total`) or an extra-long statement list (past the CSS
    // default of 5) visually buries the Yes/Unsure/No buttons under the card.
    if (this.hasControlsTarget) this.controlsTarget.style.zIndex = String(total + 1)
    this.cardTargets.forEach((card, i) => {
      const offset = i - this.position
      if (offset < 0) {
        card.style.opacity = "0"
        card.style.pointerEvents = "none"
        return
      }
      const visible = offset <= 2
      card.style.transition = this.formsMode ? "none" : "transform 250ms ease, opacity 250ms ease"
      card.style.opacity    = visible ? "1" : "0"
      card.style.pointerEvents = offset === 0 ? "auto" : "none"
      card.style.zIndex     = String(total - offset)
      const scale = 1 - offset * 0.04
      const ty    = offset * 6
      const rot   = offset === 1 ? "1deg" : offset === 2 ? "-2deg" : "0deg"
      card.style.transform  = `translateY(${ty}px) scale(${scale}) rotate(${rot})`
    })
    if (this.hasCounterTarget) {
      this.counterTarget.textContent = `${Math.min(this.position + 1, total)} / ${total}`
    }
  }

  // One dot per card; dots before the current position read as "done", the
  // current one is "active", the rest are upcoming — a remaining-cards gauge.
  _syncDots(total) {
    if (!this.hasDotsTarget) return
    const box = this.dotsTarget
    while (box.children.length < total) {
      const d = document.createElement("span")
      d.className = "rotate-dot"
      box.appendChild(d)
    }
    while (box.children.length > total) box.lastElementChild.remove()
    Array.from(box.children).forEach((dot, i) => {
      dot.classList.toggle("done", i < this.position)
      dot.classList.toggle("active", i === this.position)
    })
  }
}
