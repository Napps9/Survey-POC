import { Controller } from "@hotwired/stimulus"
import { EMOJI_CATEGORIES, searchEmoji } from "lib/emoji_library"
import { t } from "lib/i18n"

// A shared emoji picker for every emoji field in the editor.
//
// Before this, the only way to put an emoji anywhere — an option's icon, a
// token type — was the operating system's own emoji keyboard (⌃⌘Space, or the
// Windows/mobile equivalent). Plenty of creators don't know it exists, and on
// some setups it isn't reachable at all, so the fields looked decorative.
//
// One popover serves every field: a trigger button sets `_input` to the input
// it belongs to, and picking writes the value and dispatches a real `input`
// event so the field's existing handler (option-style#onEmoji,
// token-types#save) runs exactly as if it had been typed.
export default class extends Controller {
  static targets = [ "popover", "search", "grid", "tabs" ]

  connect() {
    this._input = null
    this._category = EMOJI_CATEGORIES[0]?.key
    this._escListener = (e) => { if (e.key === "Escape") this.close() }
    this._outsideListener = (e) => {
      if (this.popoverTarget.hidden) return
      if (this.popoverTarget.contains(e.target)) return
      if (e.target.closest("[data-emoji-picker-trigger]")) return
      this.close()
    }
    document.addEventListener("keydown", this._escListener)
    document.addEventListener("mousedown", this._outsideListener)
    this._renderTabs()
  }

  disconnect() {
    document.removeEventListener("keydown", this._escListener)
    document.removeEventListener("mousedown", this._outsideListener)
  }

  // Opened by any button carrying data-emoji-picker-trigger. The field it
  // fills is the one named by data-emoji-picker-for (a selector) or, failing
  // that, the nearest input beside the button — so a trigger can be dropped
  // next to a field without wiring anything up.
  open(event) {
    event?.preventDefault()
    event?.stopPropagation()
    const trigger = event.currentTarget
    const selector = trigger.dataset.emojiPickerFor
    this._input = (selector && document.querySelector(selector)) ||
      trigger.parentElement?.querySelector("input[type='text'], input:not([type])")
    if (!this._input) return

    this.searchTarget.value = ""
    this._category = EMOJI_CATEGORIES[0]?.key
    this._renderTabs()
    this._renderGrid()
    this.popoverTarget.hidden = false
    this._position(trigger)
    this.searchTarget.focus()
  }

  close() {
    this.popoverTarget.hidden = true
    this._input = null
  }

  onSearch() {
    this._renderGrid()
  }

  pickCategory(event) {
    this._category = event.currentTarget.dataset.category
    this._renderTabs()
    this._renderGrid()
  }

  // Writing the value is only half of it — the `input` event is what makes the
  // owning controller persist it, so a picked emoji behaves exactly like a
  // typed one.
  pick(event) {
    const emoji = event.currentTarget.dataset.emoji
    if (!this._input || !emoji) return
    this._input.value = emoji
    this._input.dispatchEvent(new Event("input", { bubbles: true }))
    this._input.dispatchEvent(new Event("change", { bubbles: true }))
    this.close()
  }

  clear() {
    if (!this._input) return
    this._input.value = ""
    this._input.dispatchEvent(new Event("input", { bubbles: true }))
    this._input.dispatchEvent(new Event("change", { bubbles: true }))
    this.close()
  }

  _renderTabs() {
    if (!this.hasTabsTarget) return
    this.tabsTarget.innerHTML = EMOJI_CATEGORIES.map(c => `
      <button type="button" class="emoji-picker-tab${c.key === this._category ? " is-active" : ""}"
              data-category="${c.key}" data-action="click->emoji-picker#pickCategory">${c.label}</button>
    `).join("")
  }

  _renderGrid() {
    const query = this.searchTarget.value.trim()
    const list = query
      ? searchEmoji(query)
      : (EMOJI_CATEGORIES.find(c => c.key === this._category)?.emoji || []).map(([ e ]) => e)

    if (!list.length) {
      this.gridTarget.innerHTML =
        `<div class="emoji-picker-empty">${t("editor.emoji_none", { default: "No emoji match that." })}</div>`
      return
    }
    this.gridTarget.innerHTML = list.map(e => `
      <button type="button" class="emoji-picker-item" data-emoji="${e}"
              data-action="click->emoji-picker#pick" aria-label="${e}">${e}</button>
    `).join("")
  }

  // Anchored to the trigger, flipped up or left when it would otherwise run
  // off-screen — the token-type rows sit low in a right-hand panel.
  _position(trigger) {
    const r = trigger.getBoundingClientRect()
    const pop = this.popoverTarget
    const w = pop.offsetWidth || 300
    const h = pop.offsetHeight || 340
    let top = r.bottom + 6
    let left = r.left
    if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 6)
    if (left + w > window.innerWidth - 8) left = Math.max(8, window.innerWidth - w - 8)
    pop.style.top = `${top}px`
    pop.style.left = `${left}px`
  }
}
