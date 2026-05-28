import { Controller } from "@hotwired/stimulus"

const SWIPE_FILLS = [
  ["#d4edda","#a8d5b5"], ["#d1ecf1","#9fd5df"], ["#fff3cd","#ffd88a"],
  ["#f8d7da","#f5a8b0"], ["#e2d9f3","#c3aee8"]
]

export default class extends Controller {
  deleteOption(event) {
    event.stopPropagation()
    const item = event.currentTarget.closest(".pick-item, .rotate-card")
    if (item) { item.remove(); this.dispatch("changed") }
  }

  addPickOption() {
    const addBtn  = this.element.querySelector("[data-card-editor-add]")
    const isMulti = this.element.dataset.pickerModeValue === "multi"
    const li = document.createElement("li")
    li.className = "pick-item"
    li.dataset.pickerTarget = "item"
    li.dataset.action = "click->picker#pick"
    li.dataset.selected = "false"
    li.innerHTML = `
      <span class="${isMulti ? "pick-square" : "pick-dot"}">✓</span>
      <span class="pick-text" contenteditable="true">New option</span>
      <button type="button" class="pick-item-delete" data-action="click->card-editor#deleteOption">×</button>
    `
    addBtn ? addBtn.before(li) : this.element.appendChild(li)
    this.dispatch("changed")
    const editable = li.querySelector("[contenteditable]")
    editable?.focus()
    // Select all text so user can immediately type replacement
    if (editable) {
      const range = document.createRange()
      range.selectNodeContents(editable)
      window.getSelection()?.removeAllRanges()
      window.getSelection()?.addRange(range)
    }
  }

  addTapOption() {
    const stack = this.element.querySelector(".rotate-card-stack")
    if (!stack) return
    const n = stack.querySelectorAll(".rotate-card").length

    // If this card was populated (option_images is non-empty), match the
    // populated look on the new statement by picking an unused swipe-card
    // URL. Otherwise fall back to the colourful gradient.
    const cardRow  = this.element.closest('[data-survey-editor-target="card"]')
    const existing = this._readOptionImages(cardRow)
    const newImage = existing.length > 0 ? this._pickSwipeUrl(existing) : null

    const card = document.createElement("div")
    card.className = "rotate-card"
    card.dataset.tapStackTarget = "card"
    if (newImage) {
      card.style.background = `#fff url('${newImage}') center/cover no-repeat`
    } else {
      const [a, b] = SWIPE_FILLS[n % SWIPE_FILLS.length]
      card.style.background = `linear-gradient(135deg,${a},${b})`
    }
    const textStyle = newImage
      ? "font-family:'ABeeZee',sans-serif;font-size:14px;color:#111;text-align:center;background:rgba(255,255,255,0.92);padding:8px 16px;border-radius:999px;box-shadow:0 1px 3px rgba(0,0,0,0.08);max-width:80%;"
      : "font-family:'ABeeZee',sans-serif;font-size:14px;color:#111;text-align:center;"
    card.innerHTML = `
      <span contenteditable="true" style="${textStyle}">New statement</span>
      <button type="button" class="tap-card-delete" data-action="click->card-editor#deleteOption">×</button>
    `
    stack.appendChild(card)

    // Persist the new URL onto the card row so autosave's serialiser includes
    // it (survey_editor reads cardOptionImages from this dataset).
    if (newImage && cardRow) {
      cardRow.dataset.cardOptionImages = JSON.stringify(existing.concat([newImage]))
    }

    this.dispatch("changed")
    // Notify tap-stack controller to re-layout
    const tapStack = this.element.querySelector("[data-controller~='tap-stack']") || this.element
    tapStack.dispatchEvent(new Event("tap-stack:reset"))
    const editable = card.querySelector("[contenteditable]")
    editable?.focus()
    if (editable) {
      const range = document.createRange()
      range.selectNodeContents(editable)
      window.getSelection()?.removeAllRanges()
      window.getSelection()?.addRange(range)
    }
  }

  _readOptionImages(cardRow) {
    if (!cardRow) return []
    try {
      const v = JSON.parse(cardRow.dataset.cardOptionImages || "[]")
      return Array.isArray(v) ? v : []
    } catch (_) { return [] }
  }

  _pickSwipeUrl(existing) {
    const editor = this.element.closest("[data-swipe-card-urls]")
    if (!editor) return null
    let pool = []
    try { pool = JSON.parse(editor.dataset.swipeCardUrls || "[]") } catch (_) { return null }
    if (!Array.isArray(pool) || pool.length === 0) return null
    const unused = pool.filter(u => !existing.includes(u))
    const choices = unused.length > 0 ? unused : pool  // exhausted → allow repeats
    return choices[Math.floor(Math.random() * choices.length)]
  }
}
