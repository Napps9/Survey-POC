import { Controller } from "@hotwired/stimulus"
import { indexForDirection } from "lib/tap_scales"
import { t } from "lib/i18n"

// Card-stack widget. Each card is a tap-stack#card target.
//
// The response strip is 2-6 answers wide (TapScales). Each carries the value it
// stores as data-tap-stack-key and the way the card should fly as
// data-tap-stack-direction, both resolved server-side from the card's scale — so
// this controller never has to know what a scale contains, only what the button
// it was handed says. On click, the top card animates off-screen in that
// direction and the next card surfaces.
export default class extends Controller {
  static targets = ["card", "counter", "dots", "controls", "prevBtn", "nextBtn"]

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
    if (event.target.closest(".option-style-btn, .tap-response-delete")) return
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

    // Read live, because the card's height is fluid — it grows into whatever
    // its panel has between a 430px floor and a 560px ceiling, so there is no
    // single right number to hard-code. The fallbacks only fire on a zero rect
    // (a stack that is display:none), and are the floor rather than a guess at
    // the current size: under-reading the height makes the up-fling threshold
    // easier, which fails safe.
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
    // Cancels the player's pending auto-advance: Reset on the all-answered
    // face means "I want to change something", the opposite of moving on.
    // "cleared", not "reset" — the stack LISTENS for tap-stack:reset as an
    // external command (the card wrap re-dispatches it), so announcing under
    // the same name would re-trigger this method forever.
    this.dispatch("cleared")
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

  // ── Walking the deck without answering it (editor only) ─────────────────
  // A respondent moves the stack by answering: pick() and the drag both land
  // on _commit, which throws the top card off and surfaces the next. A creator
  // has no such move. In the editor every pixel of the response strip is
  // already spoken for — the mark opens the 🎨 popover, the label holds a
  // caret, the 🎨 and × are their own buttons — so pick() has no click target
  // left, and the deck simply never advanced. Statement 2 onwards could not be
  // read, edited, given a picture or deleted: only the top card takes pointer
  // events, and only the first card is ever the top card.
  //
  // So the editor gets a pager instead. It moves `position` and re-lays out,
  // and that is all: nothing is recorded, so stepping past a statement is not
  // an answer to it and stepping back does not take one away.
  //
  // Both stop propagation, for the reason pick() and every other control on
  // this card do: the click would otherwise fall through and select/apply the
  // type underneath. Turning to the next statement is not a request to open
  // the Answer Type panel, and the panel opening moves the card under the
  // pointer — so the side effect also took the second chevron out from under
  // the click that was aimed at it.
  forward(event) { if (event) { event.preventDefault(); event.stopPropagation() } this._goTo(this.position + 1) }
  back(event)    { if (event) { event.preventDefault(); event.stopPropagation() } this._goTo(this.position - 1) }

  // The same jump as an external command, for the editor's own edits —
  // card-editor#addTapOption lands on the statement it has just appended, and
  // #deleteOption stays where the creator was rather than snapping to the
  // front. `index: -1` means "the last one", which is what an append wants
  // without having to count the cards from outside.
  goto(event) {
    const index = event?.detail?.index
    if (typeof index !== "number") return
    this._goTo(index < 0 ? this.cardTargets.length - 1 : index)
  }

  // Clamped, so a caller may hand over an index that no longer exists (the
  // statement it names has just been deleted) and still land somewhere real.
  _goTo(index) {
    const total = this.cardTargets.length
    if (total === 0) return
    this.position = Math.max(0, Math.min(index, total - 1))
    this.layout()
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
      this.counterTarget.textContent =
        t("editor.tap.statement_of", { n: Math.min(this.position + 1, total), total })
    }
    // Both ends of the pager say so rather than going quiet: a dead-looking
    // chevron is the only thing that tells a creator the deck has no more
    // statements, since the stack itself looks the same either way.
    if (this.hasPrevBtnTarget) this.prevBtnTarget.disabled = this.position <= 0
    if (this.hasNextBtnTarget) this.nextBtnTarget.disabled = this.position >= total - 1
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
