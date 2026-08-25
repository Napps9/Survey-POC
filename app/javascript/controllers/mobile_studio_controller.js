import { Controller } from "@hotwired/stimulus"
import { t } from "lib/i18n"

// The phone editor shell — "the card IS the editor".
//
// On a phone the creator sees the live card exactly as a respondent would
// (hero, in-card progress, white panel, Back/Next footer), with the only
// creator chrome FLOATING over it: a top bar (back · title · preview · more)
// and a glass dock (Design · Add · Settings · Share). This controller owns
// none of the editing — every action delegates to the desktop controllers
// already mounted on the same root (survey-editor, publish-panel,
// editor-panel, add-question, flows, type-panel), so the two editors cannot
// drift apart.
//
// The mechanism is deliberately just CLASSES: at ≤767px the cards feed gains
// `preview-overlay m-studio`. `preview-overlay` is the player's own mobile
// scope — its entire phone card system (45/55 hero split, the 22px lip,
// in-card progress, input font floors) applies to the editor's editable cards
// with zero player-CSS edits; `m-studio` carries the editor-only geometry
// (full-height snap pages, hidden rails) in application.css's M-STUDIO block.
// Above 767px the classes are absent and the desktop editor is byte-identical.
export default class extends Controller {
  static targets = ["stage", "chrome", "titleText", "progressChip", "menu"]

  // The one width the studio calls a phone — the same flat test the CSS
  // blocks use. Not pointer-based, so a narrow window (and the system tests'
  // 390×844 browser) exercises the real path.
  static QUERY = "(max-width: 767px)"

  connect() {
    this._mq = window.matchMedia(this.constructor.QUERY)
    this._onChange = () => this._apply()
    // Safari <14 took listeners via addListener only; everything current is
    // addEventListener. The app already assumes modern Safari elsewhere.
    this._mq.addEventListener("change", this._onChange)

    this._onScroll = () => this._scrolled()
    this._onFocusIn = (e) => this._focusChanged(e, true)
    this._onFocusOut = (e) => this._focusChanged(e, false)
    this._apply()
  }

  disconnect() {
    this._mq?.removeEventListener("change", this._onChange)
    this._exit()
  }

  // ── Entering / leaving the phone shell ──────────────────────────────────

  _apply() {
    this._mq.matches ? this._enter() : this._exit()
  }

  _enter() {
    if (!this.hasStageTarget || this._on) return
    this._on = true
    const stage = this.stageTarget
    // device-mobile/tablet are the desktop editor's PREVIEW bezels — a
    // different, simpler construction than the player's real phone layout.
    // The stage must never wear both; the shell always previews true.
    stage.classList.remove("device-mobile", "device-tablet")
    stage.classList.add("device-desktop", "preview-overlay", "m-studio")
    this.element.classList.add("m-studio-on")
    stage.addEventListener("scroll", this._onScroll, { passive: true })
    stage.addEventListener("focusin", this._onFocusIn)
    stage.addEventListener("focusout", this._onFocusOut)
    this._syncChip()
  }

  _exit() {
    if (!this._on) return
    this._on = false
    const stage = this.hasStageTarget ? this.stageTarget : null
    if (stage) {
      stage.classList.remove("preview-overlay", "m-studio")
      // viewport_height.js pins the first laid-out .preview-overlay by writing
      // an inline height/transform onto it. Leaving those behind would hand
      // the desktop feed a phone-sized box the moment a tablet rotates.
      stage.style.height = ""
      stage.style.transform = ""
      stage.removeEventListener("scroll", this._onScroll)
      stage.removeEventListener("focusin", this._onFocusIn)
      stage.removeEventListener("focusout", this._onFocusOut)
    }
    this.element.classList.remove("m-studio-on", "m-typing", "m-scrolling")
    clearTimeout(this._scrollIdle)
  }

  // ── Deck paging (the card's own footer is the pager) ────────────────────

  _slots() {
    return [...this.stageTarget.querySelectorAll(".card-slot")]
  }

  _activeIndex() {
    const top = this.stageTarget.scrollTop
    const slots = this._slots()
    let best = 0
    let bestDist = Infinity
    slots.forEach((slot, i) => {
      const d = Math.abs(slot.offsetTop - top)
      if (d < bestDist) { bestDist = d; best = i }
    })
    return best
  }

  prev() { this._step(-1) }
  next() { this._step(1) }

  // Step from where the deck is GOING, not from where it currently is: a
  // smooth scroll takes ~300ms, and reading scrollTop mid-flight makes a
  // second tap recompute the same card and go nowhere. Two quick taps on Next
  // must advance two cards.
  _step(delta) {
    const base = this._pending == null ? this._activeIndex() : this._pending
    this._goTo(base + delta)
  }

  _goTo(index) {
    const slots = this._slots()
    const i = Math.max(0, Math.min(slots.length - 1, index))
    const target = slots[i]
    if (!target) return
    this._pending = i
    clearTimeout(this._pendingClear)
    this._pendingClear = setTimeout(() => { this._pending = null }, 600)
    this.stageTarget.scrollTo({ top: target.offsetTop, behavior: "smooth" })
    // The creator tapped, so the answer is already known — say it now rather
    // than after the scroll settles. A counter that lags the button it sits
    // beside reads as a stuck deck.
    this._chipFor(i)
  }

  _syncChip() { this._chipFor(this._activeIndex()) }

  _chipFor(index) {
    if (!this.hasProgressChipTarget) return
    const total = this._slots().length
    if (!total) return
    this.progressChipTarget.textContent = t("player.progress", { n: index + 1, total })
  }

  // ── Chrome fade: get out of the way while the creator works ─────────────

  _scrolled() {
    this.element.classList.add("m-scrolling")
    clearTimeout(this._scrollIdle)
    this._scrollIdle = setTimeout(() => {
      this.element.classList.remove("m-scrolling")
      this._syncChip()
    }, 380)
  }

  _focusChanged(event, entering) {
    const texty = (el) =>
      !!el && (el.isContentEditable || el.tagName === "TEXTAREA" || el.tagName === "INPUT")
    if (entering && texty(event.target)) {
      // Mandatory snap fights the browser's scroll-the-caret-into-view while
      // a keyboard is up; the M-STUDIO CSS keys off m-typing to release it.
      this.element.classList.add("m-typing")
    } else if (!entering) {
      // Focus may be moving between two editables on the same card — decide
      // after the new focus has landed.
      requestAnimationFrame(() => {
        if (!texty(document.activeElement) ||
            !this.stageTarget.contains(document.activeElement)) {
          this.element.classList.remove("m-typing")
        }
      })
    }
  }

  // ── Rename (title pill mirrors the desktop contenteditable) ─────────────

  // The desktop title span owns the rename plumbing (survey-editor's
  // renameVerto reads ITS textContent). The pill just keeps it in sync and
  // pokes its input listener, so autosave, blank-guarding and truncation all
  // stay single-sourced.
  titleEdited() {
    const desk = this.element.querySelector("[data-survey-editor-target='vertoTitle']")
    if (!desk || !this.hasTitleTextTarget) return
    desk.textContent = this.titleTextTarget.textContent
    desk.dispatchEvent(new Event("input", { bubbles: true }))
  }

  titleKeydown(event) {
    if (event.key !== "Enter") return
    event.preventDefault()
    this.titleTextTarget.blur()
  }

  titleBlurred() {
    // An emptied pill falls back to the saved name, same as the desktop span.
    const desk = this.element.querySelector("[data-survey-editor-target='vertoTitle']")
    if (!this.hasTitleTextTarget || !desk) return
    if (!this.titleTextTarget.textContent.trim()) {
      this.titleTextTarget.textContent = desk.textContent
    }
  }

  // ── Overflow menu (undo · duplicate · delete live in the rail already) ──

  toggleMenu() {
    if (this.hasMenuTarget) this.menuTarget.hidden = !this.menuTarget.hidden
  }

  closeMenu() {
    if (this.hasMenuTarget) this.menuTarget.hidden = true
  }

  // Delegate to the active card's own rail buttons — hidden on a phone, but
  // their handlers carry every invariant (welcome-card rules, undo stack,
  // confirm prompts), and a synthetic click runs them all.
  _clickOnActiveCard(selector) {
    this.closeMenu()
    const slot = this._slots()[this._activeIndex()]
    slot?.querySelector(selector)?.click()
  }

  duplicateActive() { this._clickOnActiveCard(".card-duplicate-btn") }
  deleteActive() { this._clickOnActiveCard(".card-delete-btn") }
  addAfterActive() { this._clickOnActiveCard(".rail-add-btn") }
}
