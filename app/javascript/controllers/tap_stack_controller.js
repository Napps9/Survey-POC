import { Controller } from "@hotwired/stimulus"
import { indexForDirection } from "lib/tap_scales"

// Card-stack widget. Each card is a tap-stack#card target.
//
// The response strip is 2-6 answers wide (TapScales). Each carries the value it
// stores as data-tap-stack-key and the way the card should fly as
// data-tap-stack-direction, both resolved server-side from the card's scale — so
// this controller never has to know what a scale contains, only what the button
// it was handed says. On click, the top card animates off-screen in that
// direction and the next card surfaces.
export default class extends Controller {
  static targets = ["card", "counter", "dots", "controls"]

  connect() {
    this.position = 0
    this.swipeResults = {}
    // In form mode the deck loses its swipe-off animation — the card just snaps
    // to the next one — so it reads as a plain question, not a game (the answer
    // is captured from the response buttons either way).
    this.formsMode = !!this.element.closest(".forms-mode")
    this.layout()
  }

  pick(event) {
    if (event.target.isContentEditable) return
    if (event.target.closest(".option-style-btn, .tap-response-delete, .tap-response-add")) return
    event.stopPropagation() // don't also select/apply the type underneath
    const el = event.currentTarget
    this._commit(el.dataset.tapStackKey, el.dataset.tapStackDirection || "right")
  }

  // Shared answer path for the buttons and the drag: record the result, throw
  // the top card off in `dir`, surface the next one.
  _commit(key, dir) {
    const top = this.cardTargets[this.position]
    if (!top || !key) return
    // Key by the canonical (primary-language) label so tap results aggregate
    // across languages; fall back to the visible text for legacy markup.
    const label = top.dataset.canonical?.trim()
                  || top.querySelector(".rotate-card-statement span")?.textContent?.trim()
                  || top.querySelector("span")?.textContent?.trim()
                  || `Card ${this.position + 1}`
    this.swipeResults[label] = key
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

  // The response buttons, in scale order (most-negative first).
  get _responses() {
    return Array.from(this.element.querySelectorAll("[data-tap-response]"))
  }

  // Which response a fling in `dir` commits. A drag can only ever express three
  // intents, so on a wider scale it commits the most extreme answer on that side
  // — tapping is how a respondent picks the ones in between. null when the
  // gesture has no answer to give (a fling upward on an even scale), and the
  // card snaps back rather than guessing.
  _responseForDirection(dir) {
    const list = this._responses
    const i = indexForDirection(dir, list.length)
    return i === null ? null : list[i]
  }

  // ── Pointer drag — the swipe the copy has promised all along ──────────
  // Player only (the action is rendered `unless editable`; editor statements
  // are contenteditable and a drag would fight text selection). Same shape as
  // prioritise_controller: pointer capture, window-level move/up/cancel, and
  // a full three-listener teardown on every terminal path so a lost pointerup
  // can't leave a stuck half-dragged card.
  dragStart(event) {
    if (this.formsMode) return // form mode has no swipe animation — buttons only
    if (this.dragCard) return
    if (event.target.isContentEditable) return
    if (event.target.closest("button")) return
    const card = event.currentTarget
    if (card !== this.cardTargets[this.position]) return
    event.preventDefault()

    const stack = card.parentElement.getBoundingClientRect()
    this.dragCard = card
    this.dragW    = stack.width  || 320
    this.dragH    = stack.height || 430
    this.dragX0   = event.clientX
    this.dragY0   = event.clientY
    this.dragT0   = event.timeStamp

    card.style.transition = "none" // follow the finger 1:1
    try { card.setPointerCapture(event.pointerId) } catch (_) { /* older browsers */ }

    this._onDragMove   = (e) => this._dragMove(e)
    this._onDragUp     = (e) => this._dragEnd(e)
    this._onDragCancel = () => this._dragCancel()
    window.addEventListener("pointermove",   this._onDragMove)
    window.addEventListener("pointerup",     this._onDragUp)
    window.addEventListener("pointercancel", this._onDragCancel)
  }

  _dragMove(event) {
    if (!this.dragCard) return
    const dx  = event.clientX - this.dragX0
    const dy  = event.clientY - this.dragY0
    // Rotation follows the horizontal pull toward the same ±15° the fling
    // exits at, so a committed release continues the arc it started.
    const rot = Math.max(-15, Math.min(15, dx * 0.08))
    this.dragCard.style.transform = `translate(${dx}px, ${dy}px) rotate(${rot}deg)`
    // Light up the button the release would press. The strip is keyed off the
    // response itself rather than a direction class, because on a 4-or-6 point
    // scale two responses share a direction and only one of them — the extreme
    // — is the one a release would commit.
    this._markIntent(this._dragIntent(dx, dy))
  }

  _markIntent(dir) {
    if (this.hasControlsTarget) this.controlsTarget.dataset.intent = dir || ""
    const wanted = dir ? this._responseForDirection(dir) : null
    this._responses.forEach((el) => el.classList.toggle("is-intent", el === wanted))
  }

  // Which direction a release at (dx, dy) means, or null for "not far enough".
  // Horizontal beats vertical unless the pull is clearly upward — the middle
  // answer is deliberately the hardest gesture to hit by accident.
  _dragIntent(dx, dy) {
    if (dy <= -Math.max(64, this.dragH * 0.22) && Math.abs(dy) > Math.abs(dx)) return "up"
    if (dx >=  Math.max(72, this.dragW * 0.30)) return "right"
    if (dx <= -Math.max(72, this.dragW * 0.30)) return "left"
    return null
  }

  _dragEnd(event) {
    const card = this.dragCard
    if (!card) return
    const dx = event.clientX - this.dragX0
    const dy = event.clientY - this.dragY0
    const dt = Math.max(1, event.timeStamp - this.dragT0)
    let dir  = this._dragIntent(dx, dy)
    // A quick horizontal flick commits before the distance threshold.
    if (!dir && Math.abs(dx) >= 24 && Math.abs(dx) > Math.abs(dy) && Math.abs(dx) / dt >= 0.5) {
      dir = dx > 0 ? "right" : "left"
    }
    this._dragTeardown()
    // A fling upward on an even scale has no middle answer to land on, so it is
    // no answer at all — the card snaps back rather than being rounded to a
    // neighbour the respondent didn't choose.
    const target = dir ? this._responseForDirection(dir) : null
    if (target) {
      // sets its own transition; animates on from the dragged pose
      this._commit(target.dataset.tapStackKey, target.dataset.tapStackDirection || dir)
    } else {
      this.layout() // snap back to the resting stack transform
    }
  }

  // The browser fires pointercancel when it claims the gesture for itself
  // (alert, tab switch). Restore the stack; nothing is committed.
  _dragCancel() {
    if (!this.dragCard) return
    this._dragTeardown()
    this.layout()
  }

  _dragTeardown() {
    this.dragCard = null
    if (this.hasControlsTarget) delete this.controlsTarget.dataset.intent
    this._responses.forEach((el) => el.classList.remove("is-intent"))
    window.removeEventListener("pointermove",   this._onDragMove)
    window.removeEventListener("pointerup",     this._onDragUp)
    window.removeEventListener("pointercancel", this._onDragCancel)
  }

  disconnect() {
    this._dragTeardown()
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
    // Deck exhausted → the .rotate-complete face replaces the cards and the
    // controls bow out (all CSS, keyed off this class). Running it here rather
    // than in pick() means reset() and re-connect clear it for free.
    this.element.classList.toggle("is-complete", total > 0 && this.position >= total)
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
