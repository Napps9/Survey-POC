import { Controller } from "@hotwired/stimulus"
import { FONT_LABELS, SIZE_LABELS, FONT_CLASSES, SIZE_CLASSES } from "lib/rich_text"

// The floating rich-text toolbar (editor only). Appears over a text selection
// inside any [data-rich-text] contenteditable region; B/I/U toggles plus font
// and size selects that wrap the selection in the allowlisted markup
// (lib/rich_text.js ↔ RichTextSanitizer).
//
// Manual range wrapping, NOT document.execCommand: execCommand is deprecated,
// emits <font>/style-attribute markup the sanitiser would reject, and differs
// across browsers. extractContents → wrap → normalize produces exactly the
// markup the allowlist accepts; imperfect nesting from repeated toggling is
// fine — the server sanitiser and the textContent-canonical plain layer are
// the safety net.
export default class extends Controller {
  static targets = ["toolbar", "fontSelect", "sizeSelect", "boldBtn", "italicBtn", "underlineBtn"]

  connect() {
    this._buildSelects()
    this._onSelection = () => {
      cancelAnimationFrame(this._raf)
      this._raf = requestAnimationFrame(() => this._selectionChanged())
    }
    document.addEventListener("selectionchange", this._onSelection)
    // Keep the selection alive while pressing toolbar BUTTONS. Selects need
    // real focus for their dropdowns, so they work off the saved range.
    this._onToolbarMousedown = (e) => {
      if (e.target.closest("button")) e.preventDefault()
    }
    if (this.hasToolbarTarget) this.toolbarTarget.addEventListener("mousedown", this._onToolbarMousedown)
  }

  disconnect() {
    document.removeEventListener("selectionchange", this._onSelection)
    cancelAnimationFrame(this._raf)
  }

  // ── Selection tracking ────────────────────────────────────────────────────

  _selectionChanged() {
    const sel = window.getSelection()
    if (!this.hasToolbarTarget) return
    if (document.activeElement && this.toolbarTarget.contains(document.activeElement)) return
    const range = sel && sel.rangeCount ? sel.getRangeAt(0) : null
    const region = range && this._region(range)
    if (!range || range.collapsed || !region) {
      this.toolbarTarget.hidden = true
      return
    }
    this._range = range.cloneRange()
    this._regionEl = region
    this._reflect(range, region)
    this._position(range)
    this.toolbarTarget.hidden = false
  }

  _region(range) {
    let node = range.commonAncestorContainer
    if (node.nodeType === Node.TEXT_NODE) node = node.parentElement
    const region = node?.closest?.("[data-rich-text]")
    return region && this.element.contains(region) ? region : null
  }

  _position(range) {
    const rect = range.getBoundingClientRect()
    const pop = this.toolbarTarget
    pop.style.top = `${Math.max(8, rect.top - 48)}px`
    pop.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - 340))}px`
  }

  // Reflect the current formats at the selection into the controls.
  _reflect(range, region) {
    let node = range.startContainer
    if (node.nodeType === Node.TEXT_NODE) node = node.parentElement
    const within = (sel) => {
      const hit = node?.closest?.(sel)
      return hit && region.contains(hit) ? hit : null
    }
    this.boldBtnTarget.classList.toggle("is-active", !!within("b,strong"))
    this.italicBtnTarget.classList.toggle("is-active", !!within("i,em"))
    this.underlineBtnTarget.classList.toggle("is-active", !!within("u"))
    const fontSpan = FONT_CLASSES.map(c => within(`span.${c}`)).find(Boolean)
    this.fontSelectTarget.value = fontSpan ? FONT_CLASSES.find(c => fontSpan.classList.contains(c)) : ""
    const sizeSpan = SIZE_CLASSES.map(c => within(`span.${c}`)).find(Boolean)
    this.sizeSelectTarget.value = sizeSpan ? SIZE_CLASSES.find(c => sizeSpan.classList.contains(c)) : ""
  }

  // ── Formatting actions ────────────────────────────────────────────────────

  bold(event) { event.preventDefault(); this._toggleTag("b", "b,strong") }
  italic(event) { event.preventDefault(); this._toggleTag("i", "i,em") }
  underline(event) { event.preventDefault(); this._toggleTag("u", "u") }

  fontChanged() { this._setClass(FONT_CLASSES, this.fontSelectTarget.value) }
  sizeChanged() { this._setClass(SIZE_CLASSES, this.sizeSelectTarget.value) }

  _toggleTag(tag, matchSel) {
    const range = this._liveRange()
    if (!range) return
    const region = this._regionEl
    if (this._rangeFullyWithin(range, region, matchSel)) {
      // Unwrap every matching element the selection touches. Coarse at the
      // edges of a partial selection, but predictable — and reversible with
      // one more toggle.
      this._intersecting(region, matchSel, range).forEach(el => this._unwrap(el))
    } else {
      this._wrapRange(range, document.createElement(tag))
    }
    this._finish(region)
  }

  _setClass(family, cls) {
    const range = this._liveRange()
    if (!range) return
    const region = this._regionEl
    // Clear the family from every span the selection touches first…
    this._intersecting(region, family.map(c => `span.${c}`).join(","), range).forEach(el => {
      el.classList.remove(...family)
      if (!el.className.trim()) this._unwrap(el)
    })
    // …then apply the new token (empty = back to default).
    if (cls) {
      const span = document.createElement("span")
      span.className = cls
      this._wrapRange(this._liveRange() || range, span)
    }
    this._finish(region)
  }

  _wrapRange(range, wrapper) {
    try {
      wrapper.appendChild(range.extractContents())
      range.insertNode(wrapper)
      const sel = window.getSelection()
      sel.removeAllRanges()
      const r = document.createRange()
      r.selectNodeContents(wrapper)
      sel.addRange(r)
      this._range = r.cloneRange()
    } catch (_e) {
      // A selection spanning non-splittable boundaries — leave the text alone.
    }
  }

  _unwrap(el) {
    const parent = el.parentNode
    while (el.firstChild) parent.insertBefore(el.firstChild, el)
    el.remove()
  }

  _intersecting(region, selector, range) {
    return Array.from(region.querySelectorAll(selector)).filter(el => range.intersectsNode(el))
  }

  _rangeFullyWithin(range, region, selector) {
    const walker = document.createTreeWalker(region, NodeFilter.SHOW_TEXT)
    let node
    let sawAny = false
    while ((node = walker.nextNode())) {
      if (!range.intersectsNode(node) || !node.textContent.trim()) continue
      sawAny = true
      const hit = node.parentElement?.closest(selector)
      if (!hit || !region.contains(hit)) return false
    }
    return sawAny
  }

  _liveRange() {
    const sel = window.getSelection()
    if (sel && sel.rangeCount && !sel.getRangeAt(0).collapsed && this._region(sel.getRangeAt(0))) {
      this._range = sel.getRangeAt(0).cloneRange()
    }
    return this._range || null
  }

  _finish(region) {
    if (!region) return
    // Drop empty formatting husks and merge split text nodes so repeated
    // toggling doesn't accumulate junk markup.
    region.querySelectorAll("b,strong,i,em,u,span").forEach(el => {
      if (!el.textContent) el.remove()
    })
    region.normalize()
    this.dispatch("changed")
    const sel = window.getSelection()
    if (sel && sel.rangeCount) this._reflect(sel.getRangeAt(0), region)
  }

  // ── Toolbar chrome ────────────────────────────────────────────────────────

  _buildSelects() {
    if (!this.hasFontSelectTarget || this.fontSelectTarget.options.length) return
    for (const [cls, label] of Object.entries(FONT_LABELS)) {
      const opt = document.createElement("option")
      opt.value = cls
      opt.textContent = label
      if (cls) opt.className = cls
      this.fontSelectTarget.appendChild(opt)
    }
    for (const [cls, label] of Object.entries(SIZE_LABELS)) {
      const opt = document.createElement("option")
      opt.value = cls
      opt.textContent = label
      this.sizeSelectTarget.appendChild(opt)
    }
  }
}
