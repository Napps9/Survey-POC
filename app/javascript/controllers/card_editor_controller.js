import { Controller } from "@hotwired/stimulus"
import { choiceListItemHtml, prioritiseItemHtml, esc } from "lib/choice_templates"
import { tapResponseStripHtml } from "lib/tap_response_templates"
import { resolveResponses, presetFor, MIN_TAP_RESPONSES } from "lib/tap_scales"
import { optionMediaStyle } from "lib/option_media"
import { NPS_MIN_STEPS, NPS_MAX_STEPS, NPS_CLASSIC_LABELS } from "lib/nps_vessels"
import { t } from "lib/i18n"

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

  // Splice the doomed statement's image — and the reposition that belongs to
  // it — out of the card's positional arrays, so they and the statements stay
  // aligned. Called BEFORE the node is removed, while its position among its
  // siblings is still readable.
  _dropOptionImageAt(item) {
    const card = item.closest("[data-survey-editor-target='card']")
    if (!card) return

    const siblings = Array.from(card.querySelectorAll(".rotate-card"))
    const index = siblings.indexOf(item)
    if (index < 0) return

    // option_focals shifts for exactly the reason option_images does: leave it
    // and every remaining statement inherits the framing of the one before it,
    // invisibly until a reload. Trailing nulls are trimmed off with it, so a
    // card whose only repositioned statement has just gone stops carrying the
    // attribute at all.
    let focals = []
    try { focals = JSON.parse(card.dataset.cardOptionFocals || "[]") } catch (_) { focals = [] }
    if (Array.isArray(focals) && index < focals.length) {
      focals.splice(index, 1)
      while (focals.length && focals[focals.length - 1] == null) focals.pop()
      if (focals.length) card.dataset.cardOptionFocals = JSON.stringify(focals)
      else delete card.dataset.cardOptionFocals
    }

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

  // ── The NPS scale ─────────────────────────────────────────────────────────
  // Only reachable while the card is off the classic 0-10 (the ＋ and × are not
  // rendered otherwise, and survey-editor's switch is what puts them there).
  //
  // The step count is not stored — it is however many labels the column holds,
  // read straight back off the DOM by serialize() — so adding and removing a
  // stop is adding and removing a row. What IS stored on the widget is
  // `data-nps-slider-steps-value` and `aria-valuemax`, and both have to move
  // with the row or the slider goes on dividing the vessel into the old number
  // of steps: drag it and the liquid lands between two labels.

  addNpsStop(event) {
    event.stopPropagation() // don't also select/apply the type underneath
    const column = this.element.querySelector(".nps-slider-labels")
    if (!column) return
    const rows = Array.from(column.querySelectorAll(".nps-label-row"))
    if (rows.length >= NPS_MAX_STEPS) return

    const row = document.createElement("span")
    row.className = "nps-label-row"
    row.innerHTML = `
      <button type="button" class="nps-label-delete" data-action="click->card-editor#deleteNpsStop"
              title="${esc(t("card.remove_option"))}" aria-label="${esc(t("card.remove_option"))}">×</button>
      <span class="slider-label-text" data-nps-slider-target="label" contenteditable="true">${esc(this._nextNpsLabel(rows))}</span>`
    // Appended, not prepended. The column is `column-reverse`, so DOM order
    // 0..N draws bottom to top — the end of the list is the TOP of the scale,
    // which is where a scale grows.
    column.appendChild(row)

    this._syncNpsSteps()
    this._markNpsCustom()
    this.dispatch("changed")
    const editable = row.querySelector("[contenteditable]")
    editable?.focus()
    if (editable) {
      const range = document.createRange()
      range.selectNodeContents(editable)
      window.getSelection()?.removeAllRanges()
      window.getSelection()?.addRange(range)
    }
  }

  deleteNpsStop(event) {
    event.stopPropagation()
    const row = event.currentTarget.closest(".nps-label-row")
    const column = row?.parentElement
    if (!row || !column) return
    // Same floor guard as deleteOption's: below two stops there is no scale to
    // drag, and nps_slider_controller silently clamps to 2 anyway — so a card
    // cut to one would show one label against a two-step vessel.
    if (column.querySelectorAll(".nps-label-row").length <= NPS_MIN_STEPS) return
    row.remove()
    this._syncNpsSteps()
    this._markNpsCustom()
    this.dispatch("changed")
  }

  // Using ＋ or × IS the creator saying this is their scale, so record it.
  //
  // Not housekeeping: without it a card that only DERIVED as custom — the three
  // options a type switch carried across, say — could be edited back to exactly
  // 0-10, at which point the derivation flips to "classic" and the panel switch
  // would come back on while the card still carried its ＋ and ×. The flag ends
  // the derivation the moment there is a real answer to give.
  _markNpsCustom() {
    const cardRow = this.element.closest('[data-survey-editor-target="card"]')
    if (cardRow) cardRow.dataset.cardNpsCustomScale = "true"
  }

  // Lock the scale back to 0-10, or unlock it. Called by survey-editor's
  // "Classic 0–10 scale" switch, which owns the card's dataset; this owns the
  // markup.
  //
  // Locking REPLACES the labels, and says so on the switch. That is the
  // difference between this and every other control in the panel: the classic
  // is not a display mode over whatever labels happen to be there, it is the
  // eleven specific labels that make one NPS score comparable to another.
  setNpsClassic(classic) {
    const column = this.element.querySelector(".nps-slider-labels")
    if (!column) return
    const slider = this.element.classList.contains("nps-slider")
      ? this.element : this.element.querySelector(".nps-slider")

    const labels = classic
      ? NPS_CLASSIC_LABELS.slice()
      : Array.from(column.querySelectorAll(".slider-label-text")).map(el => el.textContent.trim())

    column.innerHTML = labels.map(label => `
      <span class="nps-label-row">
        ${classic ? "" : `<button type="button" class="nps-label-delete" data-action="click->card-editor#deleteNpsStop"
                title="${esc(t("card.remove_option"))}" aria-label="${esc(t("card.remove_option"))}">×</button>`}
        <span class="slider-label-text" data-nps-slider-target="label"${classic ? "" : ' contenteditable="true"'}>${esc(label)}</span>
      </span>`).join("")

    slider?.classList.toggle("is-custom-scale", !classic)
    this._syncNpsAddBtn(slider, classic)
    this._syncNpsSteps()
  }

  // The ＋ is rendered by the server only for a card that is already off the
  // classic, so flipping the switch has to put it there or take it away —
  // otherwise the control the creator has just enabled is missing until the
  // next reload, which is the same defect the "Change animation" CTA had.
  _syncNpsAddBtn(slider, classic) {
    if (!slider) return
    const existing = slider.querySelector("[data-card-editor-nps-add]")
    if (classic) { existing?.remove(); return }
    if (existing) return
    const btn = document.createElement("button")
    btn.type = "button"
    btn.className = "nps-scale-add"
    btn.dataset.action = "click->card-editor#addNpsStop"
    btn.dataset.cardEditorNpsAdd = ""
    btn.innerHTML = `<span aria-hidden="true">＋</span> ${esc(t("card.add_scale_point"))}`
    slider.appendChild(btn)
  }

  // A numeric scale carries on counting; a worded one gets the same placeholder
  // every other list uses. Read off the LAST row because that is the top of the
  // scale (column-reverse, above) and therefore the one a new stop follows.
  _nextNpsLabel(rows) {
    const last = rows[rows.length - 1]?.querySelector(".slider-label-text")?.textContent?.trim()
    if (last != null && /^-?\d+$/.test(last)) return String(Number(last) + 1)
    return t("card.new_option")
  }

  // The widget's own idea of how many steps it has. Kept in step here rather
  // than left to the next server render, because the slider is live: the
  // creator drags it the moment they have added a stop.
  _syncNpsSteps() {
    const slider = this.element.classList.contains("nps-slider")
      ? this.element : this.element.querySelector(".nps-slider")
    if (!slider) return
    const n = Math.max(NPS_MIN_STEPS, slider.querySelectorAll(".nps-label-row").length)
    slider.dataset.npsSliderStepsValue = String(n)
    slider.setAttribute("aria-valuemax", String(n - 1))
    const add = slider.querySelector("[data-card-editor-nps-add]")
    if (add) {
      add.disabled = n >= NPS_MAX_STEPS
      add.title = add.disabled ? t("card.nps_scale_max", { max: NPS_MAX_STEPS }) : ""
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
    // A fresh statement is framed at centre, cover-fit — there is no stored
    // reposition for a picture it has only just been given.
    const mediaBg = optionMediaStyle(newImage, null, n)
    // Both image chips, matching _card_component.html.erb and type_panel's
    // rebuild. This markup used to carry only the delete ×, so a statement
    // added in the editor was the one statement whose picture could not be
    // changed — or, now, repositioned — until the page was reloaded.
    card.innerHTML = `
      <div class="rotate-card-media" style="${mediaBg}"></div>
      <div class="rotate-card-statement"><span contenteditable="true">New statement</span></div>
      <button type="button" class="tap-card-image-btn" data-action="click->media-picker#openTapOption" data-media-picker-option-index="${n}" title="${esc(t("editor.change_statement_image_title"))}" aria-label="${esc(t("editor.change_statement_image_title"))}">
        <span aria-hidden="true"><svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><path d="M21 15l-5-5L5 21"></path></svg></span>
      </button>
      <button type="button" class="tap-card-adjust-btn" data-action="click->media-picker#openAdjust" data-media-picker-option-index="${n}" title="${esc(t("editor.reposition_statement_title"))}" aria-label="${esc(t("editor.reposition_statement_title"))}"${newImage ? "" : " hidden"}>
        <span aria-hidden="true"><svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v18M3 12h18"></path><path d="M9 6l3-3 3 3M9 18l3 3 3-3M6 9l-3 3 3 3M18 9l3 3-3 3"></path></svg></span>
      </button>
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
