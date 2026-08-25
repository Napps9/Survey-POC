import { Controller } from "@hotwired/stimulus"
import { choiceListItemHtml, prioritiseItemHtml, esc } from "lib/choice_templates"
import { tapResponseStripHtml } from "lib/tap_response_templates"
import { resolveResponses, presetFor, MIN_TAP_RESPONSES } from "lib/tap_scales"
import { t } from "lib/i18n"

const SWIPE_FILLS = [
  ["#d4edda","#a8d5b5"], ["#d1ecf1","#9fd5df"], ["#fff3cd","#ffd88a"],
  ["#f8d7da","#f5a8b0"], ["#e2d9f3","#c3aee8"]
]

// The fewest options a card may be cut down to from the editor. One is enough
// to keep the card a question and to give "add option" a row to clone.
const MIN_CARD_OPTIONS = 1

export default class extends Controller {
  deleteOption(event) {
    event.stopPropagation()
    const item = event.currentTarget.closest(".pick-item, .rotate-card")
    if (!item) return
    const wasTapCard = item.classList.contains("rotate-card")
    // Floor guard, matching deleteResponse's MIN_TAP_RESPONSES: a card with no
    // options left is not a question any more, and the editor gives no way back
    // — the "add" row is the only route and it needs somewhere to add to. Now
    // that the delete chip is actually visible this is reachable by accident,
    // where before it was hidden behind an invisible control.
    const peers = item.parentElement?.querySelectorAll(wasTapCard ? ".rotate-card" : ".pick-item")
    if (peers && peers.length <= MIN_CARD_OPTIONS) return
    // Read before the node goes, so the stack can be put back where the creator
    // was rather than at the front (see the dispatch below).
    const index = peers ? Array.from(peers).indexOf(item) : 0
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
    // Re-layout the stack so the remaining-cards dots update — and hold the
    // creator's place while doing it. This used to send a plain reset, which
    // put them back on statement 1: deleting the fourth of six meant walking
    // the pager forward three times to carry on where they were. The same
    // index is now the statement that took the deleted one's place, and
    // tap-stack clamps it, so deleting the last one lands on the new last.
    if (wasTapCard) {
      this.element.dispatchEvent(new CustomEvent("tap-stack:goto", { detail: { index } }))
    }
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
      <button type="button" class="tap-card-delete" data-action="click->card-editor#deleteOption" title="${esc(t("card.remove_option"))}" aria-label="${esc(t("card.remove_option"))}">×</button>
    `
    stack.appendChild(card)

    // Persist the new URL onto the card row so autosave's serialiser includes
    // it (survey_editor reads cardOptionImages from this dataset).
    if (newImage && cardRow) {
      cardRow.dataset.cardOptionImages = JSON.stringify(existing.concat([newImage]))
    }

    this.dispatch("changed")
    // Re-layout the stack AND surface the statement just added — `index: -1`
    // is "the last one", which is where an append puts it. The old plain reset
    // laid the deck out from the front, so on a deck of four or more the caret
    // below was placed in a statement the creator could not see: it was three
    // cards down the stack at opacity 0, and everything they typed went into
    // it invisibly.
    const tapStack = this.element.querySelector("[data-controller~='tap-stack']") || this.element
    tapStack.dispatchEvent(new CustomEvent("tap-stack:goto", { detail: { index: -1 } }))
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
  // are — grow to a fifth and the other four would otherwise still claim the
  // layout and the directions they had when there were four.
  //
  // There is no addResponse: the strip's ＋ was removed in favour of the
  // settings panel's "Answers per statement", which is the same decision asked
  // once instead of one-more-at-a-time. deleteResponse stays, because removing
  // a particular answer is a different question from how many there are.

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

  // Reseed from a preset, keeping the creator's own words. This used to keep
  // nothing, on the reasoning that picking "5" means wanting the five-point
  // scale rather than last scale's wording — fair while the strip's own ＋
  // could grow a scale without touching the labels. That ＋ is gone, so this
  // is the only way to resize, and discarding here would mean a creator who
  // wrote their own four answers loses all four to reach five.
  setResponsePreset(count) {
    const strip = this.element.querySelector("[data-tap-responses]")
    if (!strip) return
    const preset = presetFor(count)
    if (!preset.length) return
    this._rewriteStrip(strip, this._keepCreatorContent(strip, preset))
  }

  // Resizing a scale used to hand back the preset verbatim, wiping whatever the
  // creator had written. That was survivable while the strip carried its own ＋
  // to add one answer without disturbing the rest; now that the ＋ is gone and
  // this picker is the only way to grow a scale, dropping their wording here
  // would be plain data loss.
  //
  // Matched BY KEY, never by position. config/tap_scales.yml puts it plainly —
  // "labels are content; keys are identity" — and the scales genuinely disagree
  // about position: going 3 → 4 the middle slot changes from "unsure" to
  // "disagree", so a positional carry-over would hand one answer's wording to a
  // different answer, which is worse than losing it. A key present in both
  // scales keeps the creator's label and their 🎨 marks; a key with no
  // equivalent in the new scale (3's "unsure" has none at 4) takes the preset's,
  // because that answer no longer exists.
  //
  // Structure always comes from the preset: `key`, `glyph` and `strong` carry
  // the scale's meaning and its swipe directions, and the glyph/emoji split is
  // sized to the count (circles below five, text pills at five and six).
  _keepCreatorContent(strip, preset) {
    const existing = new Map(this._responsesFromDom(strip).map((r) => [ r.key, r ]))
    return preset.map((slot) => {
      const was = existing.get(slot.key)
      if (!was) return slot
      const kept = { ...slot }
      if (was.label) kept.label = was.label
      // The three the 🎨 popover writes — the creator's, not the preset's.
      if (was.icon)  kept.icon  = was.icon
      if (was.emoji) kept.emoji = was.emoji
      if (was.color) kept.color = was.color
      return kept
    })
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

    // Fanning is a TWO-element change and only one of them is the strip. Going
    // to five, .rotate-actions--fan takes the strip out of flow and stretches it
    // over the card (inset: 0), and .rotate-card-controls--fan is what gives the
    // parent a card-height box to stretch inside — without it the parent stays
    // the short bar it is in row mode, collapses to its own padding once its
    // only child goes absolute, and every pill's --tap-x/--tap-y resolves
    // against ~49px instead of 430. Which is what a creator saw: click ＋ on a
    // four-point scale and the five answers landed in a heap on top of each
    // other at the foot of the card.
    //
    // Read off `next` rather than recomputing fans(): the invariant is that the
    // two classes agree, and taking them from one source is how that is kept.
    // Captured before replaceWith, because a detached node has no ancestors.
    const controls = strip.closest(".rotate-card-controls")
    strip.replaceWith(next)
    controls?.classList.toggle("rotate-card-controls--fan",
                               next.classList.contains("rotate-actions--fan"))
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
