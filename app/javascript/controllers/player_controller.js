import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["card", "backBtn", "nextBtn", "finishBtn", "thankyou", "progress"]
  static values  = { submitUrl: String, current: { type: Number, default: 0 } }

  _answers = {}

  connect() { this._update() }

  next() {
    this._capture(this.currentValue)
    if (this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
      this._update()
    }
  }

  back() {
    this._capture(this.currentValue)
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  async finish() {
    this._capture(this.currentValue)
    const sessionToken = (typeof crypto !== "undefined" && crypto.randomUUID)
      ? crypto.randomUUID()
      : Math.random().toString(36).slice(2)
    try {
      const res = await fetch(this.submitUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_token: sessionToken, answers: this._answers })
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
    } catch (_) { /* show thankyou regardless */ }
    this._showThankyou()
  }

  _capture(idx) {
    const card = this.cardTargets[idx]
    if (!card) return
    const type   = card.dataset.cardType
    const value  = this._read(card, type)
    this._answers[String(idx)] = { type, value }
  }

  _read(card, type) {
    switch (type) {
      case "multiple_choice":
      case "yes_no":
        return card.querySelector('[data-selected="true"] .pick-text')
                   ?.textContent.trim() ?? null

      case "select_many":
        return Array.from(card.querySelectorAll('[data-selected="true"] .pick-text'))
                    .map(e => e.textContent.trim())

      case "select_one_grid":
        return card.querySelector('[data-selected="true"] .choice-label')
                   ?.textContent.trim() ?? null

      case "select_many_grid":
        return Array.from(card.querySelectorAll('[data-selected="true"] .choice-label'))
                    .map(e => e.textContent.trim())

      case "range": {
        const dots   = Array.from(card.querySelectorAll(".s-dot"))
        const active = dots.findIndex(d => d.classList.contains("active"))
        return active >= 0 ? active : null
      }

      case "rating": {
        const count = Array.from(card.querySelectorAll(".rating-star.active")).length
        return count > 0 ? count : null
      }

      case "tap_card": {
        const wrap = card.querySelector(".rotate-wrap")
        try { return JSON.parse(wrap?.dataset.swipeResults || "null") } catch { return null }
      }

      case "open_ended":
        return card.querySelector("textarea")?.value?.trim() || null

      default:
        return null
    }
  }

  _showThankyou() {
    this.cardTargets.forEach(c => c.classList.remove("active"))
    this.thankyouTarget.classList.add("active")
    this.backBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.add("hidden")
    this.finishBtnTarget.classList.add("hidden")
    this.progressTarget.textContent = ""
  }

  _update() {
    const total = this.cardTargets.length
    const idx   = this.currentValue
    this.cardTargets.forEach((c, i) => c.classList.toggle("active", i === idx))
    this.progressTarget.textContent = `Card ${idx + 1} of ${total}`
    this.backBtnTarget.classList.remove("hidden")
    this.backBtnTarget.classList.toggle("invisible", idx === 0)
    const isLast = idx === total - 1
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
  }
}
