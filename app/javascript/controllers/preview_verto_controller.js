import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "overlay", "card", "backBtn", "nextBtn",
    "finishBtn", "thankyou", "returnBtn", "progress"
  ]
  static values = { current: { type: Number, default: 0 } }

  open() {
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")
    this.currentValue = 0
    this.thankyouTarget.classList.remove("active")
    this._update()
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.classList.remove("flex")
  }

  next() {
    if (this.currentValue < this.cardTargets.length - 1) {
      this.currentValue++
      this._update()
    }
  }

  back() {
    if (this.currentValue > 0) {
      this.currentValue--
      this._update()
    }
  }

  finish() {
    this.cardTargets.forEach(c => c.classList.remove("active"))
    this.thankyouTarget.classList.add("active")
    this.backBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.add("hidden")
    this.finishBtnTarget.classList.add("hidden")
    this.returnBtnTarget.classList.remove("hidden")
    this.progressTarget.textContent = ""
  }

  returnToDesign() {
    this.close()
    // Reset so next open() starts clean
    this.thankyouTarget.classList.remove("active")
    this.returnBtnTarget.classList.add("hidden")
    this._update()
  }

  _update() {
    const total = this.cardTargets.length
    const idx   = this.currentValue

    this.cardTargets.forEach((c, i) =>
      c.classList.toggle("active", i === idx))

    this.progressTarget.textContent = `Card ${idx + 1} of ${total}`

    // Back: invisible on first card so layout doesn't shift
    this.backBtnTarget.classList.remove("hidden")
    this.backBtnTarget.classList.toggle("invisible", idx === 0)
    this.backBtnTarget.classList.remove("invisible-off")

    // Next vs Finish
    const isLast = idx === total - 1
    this.nextBtnTarget.classList.toggle("hidden", isLast)
    this.finishBtnTarget.classList.toggle("hidden", !isLast)
    this.returnBtnTarget.classList.add("hidden")
  }
}
