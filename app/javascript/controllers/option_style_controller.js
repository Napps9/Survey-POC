import { Controller } from "@hotwired/stimulus"
import { iconMap } from "lib/option_icons"
import { styleFromRow, writeStyleToRow, repaintRow } from "lib/option_styles"

// The 🎨 popover on each answer option (editor only): pick a tile colour, an
// icon from the option-icon library, or an emoji. State lives as data-option-*
// attributes on the option row itself — serialize() reads the rows, so a
// style follows its option through deletes and reorders with no extra
// bookkeeping. Lives on the editor root; one popover serves every row.
export default class extends Controller {
  static targets = ["popover", "colorInput", "hexInput", "emojiInput", "iconGrid"]

  connect() {
    this._onDocClick = (e) => {
      if (!this.hasPopoverTarget || this.popoverTarget.hidden) return
      if (this.popoverTarget.contains(e.target) || e.target.closest(".option-style-btn")) return
      // The emoji picker is a sibling popover, not a child of this one — its
      // trigger lives inside our markup but the panel it opens does not.
      // Without this, picking an emoji closed us first and cleared _row, so
      // the pick landed in the input and was never written to the option.
      if (e.target.closest(".emoji-picker-popover, [data-emoji-picker-trigger]")) return
      this.close()
    }
    this._onKeydown = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("click", this._onDocClick, true)
    document.addEventListener("keydown", this._onKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this._onDocClick, true)
    document.removeEventListener("keydown", this._onKeydown)
  }

  open(event) {
    event.preventDefault()
    event.stopPropagation()
    // An option row is an <li>; a tap card's response is a chip in the swipe
    // card's control strip. Both carry their style as the same data-option-*
    // attributes, so the popover treats them identically from here on.
    const row = event.currentTarget.closest("li, [data-tap-response]")
    if (!row || !this.hasPopoverTarget) return
    if (this._row === row && !this.popoverTarget.hidden) return this.close()
    this._row = row
    this._buildIconGrid()
    const style = styleFromRow(row) || {}
    this.colorInputTarget.value = style.color || "#ffffff"
    if (this.hasHexInputTarget) this.hexInputTarget.value = this.colorInputTarget.value
    this.emojiInputTarget.value = style.emoji || ""
    this._markIcon(style.icon || "")
    // Unhide BEFORE positioning: a hidden element measures zero, and _position
    // now measures rather than assumes. Nothing paints between these two
    // statements, so there's no flash at the old spot.
    this.popoverTarget.hidden = false
    this._position(event.currentTarget)
  }

  close() {
    if (this.hasPopoverTarget) this.popoverTarget.hidden = true
    this._row = null
  }

  onColor(event) {
    const color = event.target.value.toLowerCase()
    if (this.hasHexInputTarget) this.hexInputTarget.value = color
    this._update((style) => { style.color = color })
  }

  // The native swatch (onColor above) always carries a full, valid value —
  // this is the free-text twin next to it, so it has to tolerate a color
  // that isn't one yet: partial input while typing, a leading '#' or not, 3-
  // or 6-digit shorthand. Only a complete, valid hex commits a change; an
  // incomplete one is left alone rather than snapping the swatch to black.
  onHex(event) {
    const raw = event.target.value.trim().replace(/^#/, "")
    if (!/^([0-9a-f]{3}|[0-9a-f]{6})$/i.test(raw)) return
    const full = raw.length === 3 ? raw.split("").map((c) => c + c).join("") : raw
    const color = `#${full.toLowerCase()}`
    this.colorInputTarget.value = color
    this._update((style) => { style.color = color })
  }

  // Emoji and icon are one slot visually — picking one clears the other, so
  // what the creator just chose is always what shows.
  onEmoji(event) {
    const emoji = event.target.value.trim()
    this._update((style) => {
      delete style.icon
      emoji ? (style.emoji = emoji) : delete style.emoji
    })
    this._markIcon("")
  }

  pickIcon(event) {
    const id = event.currentTarget.dataset.iconId
    this._update((style) => {
      delete style.emoji
      style.icon === id ? delete style.icon : (style.icon = id)
    })
    this.emojiInputTarget.value = ""
    this._markIcon(styleFromRow(this._row)?.icon || "")
  }

  reset() {
    if (!this._row) return
    writeStyleToRow(this._row, null)
    repaintRow(this._row, null)
    this.colorInputTarget.value = "#ffffff"
    if (this.hasHexInputTarget) this.hexInputTarget.value = "#ffffff"
    this.emojiInputTarget.value = ""
    this._markIcon("")
    this.dispatch("changed")
  }

  _update(mutate) {
    if (!this._row) return
    const style = styleFromRow(this._row) || {}
    mutate(style)
    const next = Object.keys(style).length ? style : null
    writeStyleToRow(this._row, next)
    repaintRow(this._row, next)
    this.dispatch("changed")
  }

  // Keep the whole popover on screen. The old version assumed 320×300 while
  // the box is up to 340 tall and 272 wide, so the Reset/Done footer could sit
  // just below the viewport edge — a picker that looks cut off reads as one
  // that's broken. Measured, and clamped at both ends so a row near the top of
  // the screen can't push it off the other way.
  _position(button) {
    const rect = button.getBoundingClientRect()
    const pop = this.popoverTarget
    const { width, height } = pop.getBoundingClientRect()
    const m = 12
    const top = Math.min(rect.bottom + 8, window.innerHeight - height - m)
    const left = Math.min(rect.left - 120, window.innerWidth - width - m)
    pop.style.top = `${Math.max(m, top)}px`
    pop.style.left = `${Math.max(m, left)}px`
  }

  _buildIconGrid() {
    if (!this.hasIconGridTarget || this.iconGridTarget.childElementCount) return
    const ids = iconMap().ids
    const frag = document.createDocumentFragment()
    for (const [id, url] of Object.entries(ids)) {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "option-style-icon"
      btn.dataset.iconId = id
      btn.dataset.action = "click->option-style#pickIcon"
      btn.title = id.replace(/-/g, " ")
      const img = document.createElement("img")
      img.src = url
      img.alt = ""
      img.loading = "lazy"
      btn.appendChild(img)
      frag.appendChild(btn)
    }
    this.iconGridTarget.appendChild(frag)
  }

  _markIcon(activeId) {
    if (!this.hasIconGridTarget) return
    this.iconGridTarget.querySelectorAll(".option-style-icon").forEach((btn) => {
      btn.classList.toggle("is-active", btn.dataset.iconId === activeId)
    })
  }
}
