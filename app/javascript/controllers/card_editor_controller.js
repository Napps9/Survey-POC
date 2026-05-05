import { Controller } from "@hotwired/stimulus"

const SWIPE_FILLS = [
  ["#d4edda","#a8d5b5"], ["#d1ecf1","#9fd5df"], ["#fff3cd","#ffd88a"],
  ["#f8d7da","#f5a8b0"], ["#e2d9f3","#c3aee8"]
]

export default class extends Controller {
  deleteOption(event) {
    event.stopPropagation()
    const item = event.currentTarget.closest(".pick-item, .rotate-card")
    if (item) item.remove()
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
    const [a, b] = SWIPE_FILLS[n % SWIPE_FILLS.length]
    const card = document.createElement("div")
    card.className = "rotate-card"
    card.dataset.tapStackTarget = "card"
    card.style.background = `linear-gradient(135deg,${a},${b})`
    card.innerHTML = `
      <span contenteditable="true" style="font-family:'ABeeZee',sans-serif;font-size:14px;color:#111;text-align:center;">New statement</span>
      <button type="button" class="tap-card-delete" data-action="click->card-editor#deleteOption">×</button>
    `
    stack.appendChild(card)
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
}
