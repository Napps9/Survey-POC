// The one client-side source of option-row markup, shared by the type panel's
// component rebuilds and card_editor's "＋ Add option". Must mirror the
// server-rendered rows in app/views/shared/_card_component.html.erb — before
// this module existed, "Add option" hand-built a third, tile-less row shape
// that sat visibly mis-sized between the server-rendered rows until the next
// full reload.
//
// The serializer reads option text from `.pick-text` / `.choice-list-label` /
// `.choice-label` (survey_editor_controller.js#_optionEls) — keep those hooks
// on any markup change.
import { t } from "lib/i18n"

export function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

// A multiple_choice / select_many row. `mode` is "single" or "multi".
export function choiceListItemHtml(label, i, mode) {
  const tick = mode === "multi" ? "pick-square" : "pick-dot"
  return `
        <li class="choice-list-item pick-item" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false">
          <div class="choice-list-tile choice-bg-${(i % 6) + 1}"></div>
          <span class="pick-text choice-list-label" contenteditable="true">${esc(label)}</span>
          <span class="choice-list-tick ${tick}">✓</span>
          <button type="button" class="pick-item-delete" data-action="click->card-editor#deleteOption">×</button>
        </li>`
}

// A drag-to-rank prioritise row.
export function prioritiseItemHtml(label, i) {
  return `
        <li class="choice-list-item pick-item prioritise-item" data-prioritise-target="item"
            data-action="pointerdown->prioritise#start">
          <span class="prioritise-rank" data-prioritise-target="rank">${i + 1}</span>
          <div class="choice-list-tile choice-bg-${(i % 6) + 1}"></div>
          <span class="pick-text choice-list-label" contenteditable="true">${esc(label)}</span>
          <span class="prioritise-grip" aria-hidden="true">⋮⋮</span>
          <button type="button" class="pick-item-delete" data-action="click->card-editor#deleteOption">×</button>
        </li>`
}

// A select_one_grid / select_many_grid card.
export function choiceGridItemHtml(label, i) {
  return `
        <li class="choice-card" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false">
          <div class="choice-card-bg choice-bg-${(i % 6) + 1}">
            <div class="choice-overlay"></div>
            <div class="choice-tick">✓</div>
          </div>
          <div class="choice-label" contenteditable="true">${esc(label)}</div>
        </li>`
}

// A yes/no row: fixed pair, fixed tile colours (1 = green, 4 = red), no
// delete button — the pair is not user-extensible.
export function yesNoItemHtml(label, bg) {
  return `
        <li class="choice-list-item pick-item" data-picker-target="item"
            data-action="click->picker#pick" data-selected="false">
          <div class="choice-list-tile choice-bg-${bg}"></div>
          <span class="pick-text choice-list-label" contenteditable="true">${esc(label)}</span>
          <span class="choice-list-tick pick-dot">✓</span>
        </li>`
}

export function addOptionBtnHtml() {
  return `
      <li class="pick-add-btn" data-action="click->card-editor#addPickOption" data-card-editor-add>
        <span>＋</span> ${esc(t("card.add_option"))}
      </li>`
}
