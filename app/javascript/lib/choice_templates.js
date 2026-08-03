// The one client-side source of option-row markup, shared by the type panel's
// component rebuilds and card_editor's "＋ Add option". Must mirror the
// server-rendered rows in app/views/shared/_card_component.html.erb — before
// this module existed, "Add option" hand-built a third, tile-less row shape
// that sat visibly mis-sized between the server-rendered rows until the next
// full reload.
//
// The serializer reads option text from `.pick-text` / `.choice-list-label` /
// `.choice-label` (survey_editor_controller.js#_optionEls) — keep those hooks
// on any markup change. Per-option style overrides ({color, icon, emoji})
// arrive as the optional `style` argument and are carried as data-option-*
// attributes; explicit icons are injected asynchronously by
// lib/option_icons.js#injectIcons after insertion.
import { t } from "lib/i18n"
import { tileStyle } from "lib/option_styles"

export function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function styleAttrs(style) {
  if (!style) return ""
  let out = ""
  if (style.color) out += ` data-option-color="${esc(style.color)}"`
  if (style.icon) out += ` data-option-icon="${esc(style.icon)}"`
  if (style.emoji) out += ` data-option-emoji="${esc(style.emoji)}"`
  return out
}

function tileInner(style) {
  if (style?.emoji && !style.icon) {
    return `<span class="choice-icon-emoji" aria-hidden="true">${esc(style.emoji)}</span>`
  }
  return ""
}

function styleBtnHtml(extra = "") {
  return `<button type="button" class="option-style-btn${extra}" data-action="click->option-style#open" title="${esc(t("card.style_option"))}">🎨</button>`
}

// A multiple_choice / select_many row. `mode` is "single" or "multi".
export function choiceListItemHtml(label, i, mode, style = null) {
  const tick = mode === "multi" ? "pick-square" : "pick-dot"
  return `
        <li class="choice-list-item pick-item" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false"${styleAttrs(style)}>
          <div class="choice-list-tile choice-bg-${(i % 6) + 1}" style="${esc(tileStyle(style))}">${tileInner(style)}</div>
          <span class="pick-text choice-list-label" contenteditable="true">${esc(label)}</span>
          <span class="choice-list-tick ${tick}">✓</span>
          ${styleBtnHtml()}
          <button type="button" class="pick-item-delete" data-action="click->card-editor#deleteOption">×</button>
        </li>`
}

// A drag-to-rank prioritise row.
export function prioritiseItemHtml(label, i, style = null) {
  return `
        <li class="choice-list-item pick-item prioritise-item" data-prioritise-target="item"
            data-action="pointerdown->prioritise#start"${styleAttrs(style)}>
          <span class="prioritise-rank" data-prioritise-target="rank">${i + 1}</span>
          <div class="choice-list-tile choice-bg-${(i % 6) + 1}" style="${esc(tileStyle(style))}">${tileInner(style)}</div>
          <span class="pick-text choice-list-label" contenteditable="true">${esc(label)}</span>
          <span class="prioritise-grip" aria-hidden="true">⋮⋮</span>
          ${styleBtnHtml()}
          <button type="button" class="pick-item-delete" data-action="click->card-editor#deleteOption">×</button>
        </li>`
}

// A select_one_grid / select_many_grid card.
export function choiceGridItemHtml(label, i, style = null) {
  return `
        <li class="choice-card" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false"${styleAttrs(style)}>
          <div class="choice-card-bg choice-bg-${(i % 6) + 1}" style="${esc(tileStyle(style))}">${tileInner(style)}
            <div class="choice-overlay"></div>
            <div class="choice-tick">✓</div>
            ${styleBtnHtml(" option-style-btn-grid")}
          </div>
          <div class="choice-label" contenteditable="true">${esc(label)}</div>
        </li>`
}

// A yes/no row: fixed pair, fixed tile colours (1 = green, 4 = red), no
// delete button — the pair is not user-extensible.
export function yesNoItemHtml(label, bg, style = null) {
  return `
        <li class="choice-list-item pick-item" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false"${styleAttrs(style)}>
          <div class="choice-list-tile choice-bg-${bg}" style="${esc(tileStyle(style))}">${tileInner(style)}</div>
          <span class="pick-text choice-list-label" contenteditable="true">${esc(label)}</span>
          <span class="choice-list-tick pick-dot">✓</span>
          ${styleBtnHtml()}
        </li>`
}

export function addOptionBtnHtml() {
  return `
      <li class="pick-add-btn" data-action="click->card-editor#addPickOption" data-card-editor-add>
        <span>＋</span> ${esc(t("card.add_option"))}
      </li>`
}
