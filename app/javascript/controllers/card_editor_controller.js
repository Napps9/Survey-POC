import { Controller } from "@hotwired/stimulus"
import { choiceListItemHtml, prioritiseItemHtml } from "lib/choice_templates"
import { tapResponseStripHtml } from "lib/tap_response_templates"
import { resolveResponses, presetFor, MIN_TAP_RESPONSES, MAX_TAP_RESPONSES } from "lib/tap_scales"
import { t } from "lib/i18n"

const SWIPE_FILLS = [
  ["#d4edda","#a8d5b5"], ["#d1ecf1","#9fd5df"], ["#fff3cd","#ffd88a"],
  ["#f8d7da","#f5a8b0"], ["#e2d9f3","#c3aee8"]
]

export default class extends Controller {
  deleteOption(event) {
    event.stopPropagation()
    const item = event.currentTarget.closest(".pick-item, .rotate-card")
    if (!item) return
    const wasTapCard = item.classList.contains("rotate-card")
    // A tap card's option_images are POSITIONAL — image[i] belongs to
    // statement[i] — and serialize() bounds the array by truncating its TAIL.
    // So removing a statement without removing its image shifted every picture
    // after it onto the wrong statement: delete the first of five and each
    // remaining statement inherits the one before it. On screen nothing looks
    // wrong (the backgrounds are inline on the surviving nodes), so this only
    // appeared after a reload, by which time the deck had already been saved.
    if (wasTapCard) this._dropOptionImageAt(item)
    item.remove()
    this.dispatch("changed")
    // Re-layout the stack so the remaining-cards dots update.
    if (wasTapCard) this.element.dispatchEvent(new Event("tap-stack:reset"))
  }

  // Splice the doomed statement's image out of the card's positional array, so
  // the array and the statements stay aligned. Called BEFORE the node is
  // removed, while its position among its siblings is still readable.
  _dropOptionImageAt(item) {
    const card = item.closest("[data-survey-editor-target='card']")
    if (!card) return

    const siblings = Array.from(card.querySelectorAll(".rotate-card"))
    const index = siblings.indexOf(item)
    if (index < 0) return

    let images = []
    try { images = JSON.parse(card.dataset.cardOptionImages || "[]") } catch (_) { return }
    if (!Array.isArray(images) || index >= images.length) return

    images.splice(index, 1)
    card.dataset.cardOptionImages = JSON.stringify(images)
  }

  addPickOption(event) {
    event.stopPropagation() // don't also select/apply the type underneath
    const addBtn = this.element.querySelector("[data-card-editor-add]")
    // Same shared row template the server render and the type panel use — the
    // old hand-built row here (no tile, square borders) sat visibly mis-sized
    // between the server-rendered rows until the next full reload.
    const index = this.element.querySelectorAll(".pick-item").length
    const label = t("card.new_option")
    const html = this.element.classList.contains("prioritise-list")
      ? prioritiseItemHtml(label, index)
      : choiceListItemHtml(label, index, this.element.dataset.pickerModeValue === "multi" ? "multi" : "single")
    const holder = document.createElement("template")
    holder.innerHTML = html.trim()
    const li = holder.content.firstElementChild
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

  addTapOption(event) {
    event.stopPropagation() // don't also select/apply the type underneath
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
    const mediaBg = newImage
      ? `#fff url('${newImage}') center/cover no-repeat`
      : `linear-gradient(135deg,${SWIPE_FILLS[n % SWIPE_FILLS.length].join(",")})`
    card.innerHTML = `
      <div class="rotate-card-media" style="background:${mediaBg}"></div>
      <div class="rotate-card-statement"><span contenteditable="true">New statement</span></div>
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

  // ── The response scale (tap cards) ──────────────────────────────────────
  // The strip IS the record, exactly as the option rows are: serialize() reads
  // it straight back off the DOM, so adding, removing and relabelling need no
  // bookkeeping beyond rewriting the markup. Every change rebuilds the whole
  // strip rather than splicing one node, because a response's swipe direction
  // and the circles-versus-pills shape are both functions of how many there
  // are — add a fifth by hand and the other four would still claim the layout
  // and the directions they had when there were four.

  addResponse(event) {
    event.stopPropagation() // don't also select/apply the type underneath
    const strip = event.currentTarget.closest("[data-tap-responses]")
    if (!strip) return
    const list = this._responsesFromDom(strip)
    if (list.length >= MAX_TAP_RESPONSES) return
    // Appended at the positive end: the scale reads most-negative first, so the
    // new answer is the strongest agreement until the creator says otherwise —
    // which is also why it starts on the positive glyph rather than falling
    // through to a keyword emoji, where it would be the one circle in the strip
    // not wearing the strip's own artwork.
    list.push({ key: `r_${this._randomKey()}`,
                label: t("card.new_response", { default: "New answer" }),
                glyph: "yes" })
    this._rewriteStrip(strip, list)
  }

  deleteResponse(event) {
    event.stopPropagation()
    const strip = event.currentTarget.closest("[data-tap-responses]")
    const row = event.currentTarget.closest("[data-tap-response]")
    if (!strip || !row) return
    const list = this._responsesFromDom(strip)
    // Below two there is no question left to ask. The × is hidden at the floor
    // (CSS), so this is the belt to that braces.
    if (list.length <= MIN_TAP_RESPONSES) return
    const index = Array.from(strip.querySelectorAll("[data-tap-response]")).indexOf(row)
    if (index < 0) return
    list.splice(index, 1)
    this._rewriteStrip(strip, list)
  }

  // Reseed from a preset, keeping nothing — the point of picking "5" is to get
  // the five-point scale, not to have last scale's words survive into it.
  setResponsePreset(count) {
    const strip = this.element.querySelector("[data-tap-responses]")
    if (!strip) return
    const preset = presetFor(count)
    if (preset.length) this._rewriteStrip(strip, preset)
  }

  _responsesFromDom(strip) {
    return Array.from(strip.querySelectorAll("[data-tap-response]")).map((el) => {
      const out = { key: el.dataset.responseKey }
      const label = el.querySelector("[data-tap-response-label]")?.textContent?.trim()
      if (label) out.label = label
      if (el.dataset.responseGlyph) out.glyph = el.dataset.responseGlyph
      // The 🎨 popover writes these three; they are the same data-option-*
      // attributes an option row carries, which is why option-style needs no
      // special case for a response.
      if (el.dataset.optionIcon) out.icon = el.dataset.optionIcon
      if (el.dataset.optionEmoji) out.emoji = el.dataset.optionEmoji
      if (el.dataset.optionColor) out.color = el.dataset.optionColor
      if (el.classList.contains("is-strong")) out.strong = true
      return out
    })
  }

  _rewriteStrip(strip, responses) {
    const holder = document.createElement("template")
    holder.innerHTML = tapResponseStripHtml(resolveResponses(responses)).trim()
    const next = holder.content.firstElementChild
    if (!next) return
    strip.replaceWith(next)
    this.dispatch("changed")
  }

  _randomKey() {
    const bytes = new Uint8Array(4)
    crypto.getRandomValues(bytes)
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")
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
