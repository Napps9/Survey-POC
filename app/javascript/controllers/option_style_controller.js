import { Controller } from "@hotwired/stimulus"
import { iconMap } from "lib/option_icons"
import { styleFromRow, writeStyleToRow, repaintRow } from "lib/option_styles"

// The 🎨 popover on each answer option (editor only): pick a tile colour, an
// icon from the option-icon library, or an emoji. State lives as data-option-*
// attributes on the option row itself — serialize() reads the rows, so a
// style follows its option through deletes and reorders with no extra
// bookkeeping. Lives on the editor root; one popover serves every row.
export default class extends Controller {
  static targets = ["popover", "colorInput", "emojiInput", "iconGrid"]

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
    const row = event.currentTarget.closest("li")
    if (!row || !this.hasPopoverTarget) return
    if (this._row === row && !this.popoverTarget.hidden) return this.close()
    this._row = row
    this._buildIconGrid()
    const style = styleFromRow(row) || {}
    this.colorInputTarget.value = style.color || "#ffffff"
    this.emojiInputTarget.value = style.emoji || ""
    this._markIcon(style.icon || "")
    this._position(event.currentTarget)
    this.popoverTarget.hidden = false
  }

  close() {
    if (this.hasPopoverTarget) this.popoverTarget.hidden = true
    this._row = null
  }

  onColor(event) {
    this._update((style) => { style.color = event.target.value.toLowerCase() })
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

  _position(button) {
    const rect = button.getBoundingClientRect()
    const pop = this.popoverTarget
    pop.style.top = `${Math.min(rect.bottom + 8, window.innerHeight - 320)}px`
    pop.style.left = `${Math.max(12, Math.min(rect.left - 120, window.innerWidth - 300))}px`
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
