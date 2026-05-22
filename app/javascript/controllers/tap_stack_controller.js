import { Controller } from "@hotwired/stimulus"

// Card-stack widget. Each card is a tap-stack#card target.
// Choice buttons carry data-tap-stack-direction="left|up|right".
// On click, the top card animates off-screen in that direction and the
// next card surfaces.
export default class extends Controller {
  static targets = ["card", "counter"]

  connect() {
    this.position = 0
    this.swipeResults = {}
    this.layout()
  }

  pick(event) {
    if (event.target.isContentEditable) return
    const dir = event.currentTarget.dataset.tapStackDirection || "right"
    const top = this.cardTargets[this.position]
    if (!top) return
    // Key by the canonical (primary-language) label so tap results aggregate
    // across languages; fall back to the visible text for legacy markup.
    const label = top.dataset.canonical?.trim()
                  || top.querySelector("span")?.textContent?.trim()
                  || `Card ${this.position + 1}`
    this.swipeResults[label] = dir === "right" ? "yes" : "no"
    this.element.dataset.swipeResults = JSON.stringify(this.swipeResults)
    const tx = dir === "left" ? "-120%" : dir === "right" ? "120%" : "0"
    const ty = dir === "up"   ? "-120%" : "0"
    const rot = dir === "left" ? "-15deg" : dir === "right" ? "15deg" : "0deg"
    top.style.transition = "transform 350ms ease, opacity 350ms ease"
    top.style.transform  = `translate(${tx}, ${ty}) rotate(${rot})`
    top.style.opacity    = "0"
    this.position += 1
    setTimeout(() => this.layout(), 50)
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
    this.cardTargets.forEach((card, i) => {
      const offset = i - this.position
      if (offset < 0) {
        card.style.opacity = "0"
        card.style.pointerEvents = "none"
        return
      }
      const visible = offset <= 2
      card.style.transition = "transform 250ms ease, opacity 250ms ease"
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
}
