import { Controller } from "@hotwired/stimulus"

// Keeps the right-hand editor panel pointed at the card the creator has
// actually scrolled to. Selection used to move on click alone, so scrolling
// down the feed left the panel editing a card that was no longer on screen —
// and the next thing changed in the panel (answer type, Required, branching)
// landed on the wrong question.
//
// The feed already scroll-snaps `y mandatory` with every card centred
// (application.css), so "the card you're on" is a discrete fact, not a
// heuristic: an IntersectionObserver whose root is collapsed to the feed's
// centre line reports exactly the card sitting under it. Two awkward cases fall
// out of that for free rather than needing their own branches —
//   • cards hidden inside a tabbed-away flow (.flow-hidden ⇒ display:none)
//     never intersect anything, and
//   • the consent / thank-you gates and their ＋ CTAs are snap targets but not
//     cards, so they aren't observed at all; centring one leaves the last real
//     card selected instead of blanking a panel that can't edit it.
//
// Deliberately conservative about WHEN it acts: it only ever re-points a panel
// that is already open on a card. Scrolling must never be what OPENS the panel —
// the editor opens with it collapsed and the cards centred like the player, and
// popping it out from under a scroll would be its own surprise.
export default class extends Controller {
  static targets = [ "feed", "card", "grid", "panel" ]

  // How long the feed has to hold still before the panel follows. Long enough
  // that flicking past six cards re-points the panel once, at the end, rather
  // than six times on the way — selectCardElement relocates DOM blocks, so the
  // intermediate ones would be pure thrash.
  static values = { settleMs: { type: Number, default: 140 } }

  // A deliberate click already scrolls its own card into view in several places
  // (journey jumps, leaving preview, switching flow tab), and opening the panel
  // reflows the feed over 0.28s as the grid column animates in. Both would
  // otherwise read back as "the creator scrolled". Ignore the feed for a beat
  // after any click-selection; by the time it expires the scroll has landed on
  // the card that was clicked, so the commit is a no-op anyway.
  SUPPRESS_MS = 400

  connect() {
    this._focal   = null   // the card under the centre line right now
    this._pending = null   // a commit held back because the panel had focus
    this._suppressUntil = 0

    if (!this.hasFeedTarget) return
    this._observer = new IntersectionObserver(
      entries => this._onCross(entries),
      // Collapsing the root to a zero-height band at its centre turns
      // "is it visible" into "is it the one". Percentages resolve against the
      // root's own rect, and the feed's 64/84px padding needs no compensation:
      // the observer root and the scroll snapport are both the padding box, so
      // this line and the snap centre are the same line.
      { root: this.feedTarget, rootMargin: "-50% 0px -50% 0px", threshold: 0 }
    )
    this.cardTargets.forEach(card => this._observer.observe(card))
  }

  disconnect() {
    this._observer?.disconnect()
    this._observer = null
    clearTimeout(this._settleTimer)
  }

  // Cards are inserted, duplicated, restored from the bin and deleted long after
  // load (renders_card_html re-renders the same _card_row partial), so let
  // Stimulus hand each one over instead of re-scanning the feed on every change.
  cardTargetConnected(card) {
    this._observer?.observe(card)
  }

  cardTargetDisconnected(card) {
    this._observer?.unobserve(card)
    if (this._focal === card)   this._focal = null
    if (this._pending === card) this._pending = null
  }

  // type-panel:cardSelected — a click selected a card. See SUPPRESS_MS.
  armSuppression() {
    this._suppressUntil = performance.now() + this.SUPPRESS_MS
  }

  // Focus left the panel, so a commit held back by _commit's focus guard can
  // now land. Scoped tightly: this fires for every focusout in the editor.
  focusOut(event) {
    if (!this._pending || !this.hasPanelTarget) return
    if (!this.panelTarget.contains(event.target)) return           // not the panel losing it
    if (this.panelTarget.contains(event.relatedTarget)) return     // focus stayed inside
    this._schedule()
  }

  _onCross(entries) {
    for (const entry of entries) {
      if (entry.isIntersecting) this._focal = entry.target
    }
    // Nothing under the line — a gap between cards, a gate card, the thank-you
    // CTA — leaves _focal where it was. The panel holds the last card it can
    // actually edit rather than emptying out mid-scroll.
    this._schedule()
  }

  _schedule() {
    clearTimeout(this._settleTimer)
    this._settleTimer = setTimeout(() => this._commit(), this.settleMsValue)
  }

  _commit() {
    const card = this._focal
    if (!card || !card.isConnected) return

    // Still inside the window a click opened: try again rather than give up.
    // Dropping it would strand the panel, because a scroll that has already
    // finished produces no further observer callbacks to retrigger this — and
    // if the scroll really was the click's own, the retry lands on the card
    // that was clicked and costs nothing.
    if (performance.now() < this._suppressUntil) {
      this._schedule()
      return
    }

    // Only ever a RE-target: no open panel, or no card in it yet, means there's
    // nothing pointed at the wrong question and nothing to correct.
    if (!this.hasGridTarget || !this.gridTarget.classList.contains("is-panel-open")) return
    const typePanel = this._typePanel()
    if (!typePanel?.activeCardEl) return
    // Already there — including when a click got here first, which makes any
    // re-point held back by the focus guard moot.
    if (card === typePanel.activeCardEl) { this._pending = null; return }

    // The panel physically holds blocks moved out of the selected card
    // (type-panel's Tokenomics / Quiz / Branching slots). Re-pointing it while
    // the creator is typing in one of them would move the focused node into the
    // parking lot mid-keystroke, so hold the change until they leave — focusOut
    // above picks it back up.
    if (this._focusInPanel()) {
      this._pending = card
      return
    }
    this._pending = null
    typePanel.selectCardElement(card, { source: "scroll" })
  }

  _focusInPanel() {
    const el = document.activeElement
    return !!el && this.hasPanelTarget && this.panelTarget.contains(el)
  }

  _typePanel() {
    return this.application.getControllerForElementAndIdentifier(this.element, "type-panel")
  }
}
