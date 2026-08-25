// The one client-side source of tap-card RESPONSE-STRIP markup, shared by the
// type panel's component rebuild and card_editor's add/remove. Must mirror the
// server-rendered strip in app/views/shared/_tap_responses.html.erb — the same
// contract lib/choice_templates.js holds for option rows, and for the same
// reason: before that module existed the two renderers had quietly grown apart,
// which is exactly what COMPONENTS.tap_card had already done here (it was still
// emitting two buttons, ✕ and ✓, long after the card had grown a third).
//
// test/lib/js_constant_parity_test.rb asserts the strip's classes appear in
// this file and nowhere else in app/javascript, so a fourth copy can't start.
//
// The serializer reads a response's key off `[data-response-key]` and its label
// off `[data-tap-response-label]` (survey_editor_controller.js#_readResponses) —
// keep those hooks on any markup change.
import { t } from "lib/i18n"
import { iconMap, emojiFor } from "lib/option_icons"
import { fans } from "lib/tap_scales"

// Local rather than imported from lib/choice_templates: option_styles.js needs
// tapGlyphSvg from here, choice_templates already imports option_styles, and
// borrowing four lines of escaping would close that loop into an import cycle.
function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

// The built-in swipe glyphs, mirroring ApplicationHelper::TAP_RESPONSE_ICONS.
// Duplicated rather than fetched because the editor rebuilds a strip on every
// type switch and cannot wait for a round trip; the parity test pins them to the
// Ruby constant so the two can't drift.
export const TAP_GLYPH_PATHS = {
  yes: "M1 21h4V9H1v12zm22-11c0-1.1-.9-2-2-2h-6.31l.95-4.57.03-.32c0-.41-.17-.79-.44-1.06L14.17 1 7.59 7.59C7.22 7.95 7 8.45 7 9v10c0 1.1.9 2 2 2h9c.83 0 1.54-.5 1.84-1.22l3.02-7.05c.09-.23.14-.47.14-.73v-1z",
  no: "M15 3H6c-.83 0-1.54.5-1.84 1.22l-3.02 7.05c-.09.23-.14.47-.14.73v1c0 1.1.9 2 2 2h6.31l-.95 4.57-.03.32c0 .41.17.79.44 1.06L9.83 23l6.59-6.59c.36-.36.58-.86.58-1.41V5c0-1.1-.9-2-2-2zm4 0v12h4V3h-4z",
  unsure: "M11 18h2v-2h-2v2zm1-16C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-14c-2.21 0-4 1.79-4 4h2c0-1.1.9-2 2-2s2 .9 2 2c0 2-3 1.75-3 5h2c0-2.25 3-2.5 3-5 0-2.21-1.79-4-4-4z"
}

export function tapGlyphSvg(name) {
  const path = TAP_GLYPH_PATHS[name] || TAP_GLYPH_PATHS.unsure
  return `<svg class="rotate-action-icon" viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true" focusable="false"><path d="${path}"/></svg>`
}

// A response's mark, in the same precedence ApplicationHelper#tap_response_mark
// uses: the creator's explicit icon beats their emoji beats the scale's glyph,
// with a keyword emoji as the last resort so a mark slot is never empty.
function markHtml(response, index) {
  const url = response.icon ? iconMap().ids[response.icon] : null
  if (url) return `<img src="${esc(url)}" alt="" loading="lazy">`
  if (response.emoji) return `<span class="choice-icon-emoji" aria-hidden="true">${esc(response.emoji)}</span>`
  if (response.glyph) return tapGlyphSvg(response.glyph)
  return `<span class="choice-icon-emoji" aria-hidden="true">${esc(emojiFor(response.label, index))}</span>`
}

function styleAttrs(response) {
  return [
    response.color ? ` data-option-color="${esc(response.color)}"` : "",
    response.icon ? ` data-option-icon="${esc(response.icon)}"` : "",
    response.emoji ? ` data-option-emoji="${esc(response.emoji)}"` : ""
  ].join("")
}

// One response. Always the editor flavour — the type panel and card_editor only
// ever run there; the player's <button> variant is server-rendered and never
// rebuilt client-side.
export function tapResponseHtml(response, index) {
  const cls = `rotate-action${response.strong ? " is-strong" : ""}`
  // Colour and place on the arc ride in as custom properties; the row layout
  // simply ignores the coordinates. See _tap_responses.html.erb.
  const vars = [
    response.color ? `--tap-response-color: ${esc(response.color)};` : "",
    response.fan ? `--tap-x: ${response.x}%; --tap-y: ${response.y}%;` : ""
  ].join("")
  const style = vars ? ` style="${vars}"` : ""
  return `
    <div class="${cls}"${style}
         data-tap-response
         data-response-key="${esc(response.key)}"
         data-response-glyph="${esc(response.glyph || "")}"
         data-action="click->tap-stack#pick"
         data-tap-stack-key="${esc(response.key)}"
         data-tap-stack-direction="${esc(response.direction)}"${styleAttrs(response)}>
      <span class="rotate-action-btn rotate-action-btn--editable" aria-hidden="true"
            data-action="click->option-style#open"
            title="${esc(t("card.style_option"))}">${markHtml(response, index)}</span>
      <span class="rotate-action-label" contenteditable="true" data-tap-response-label>${esc(response.label)}</span>
      <button type="button" class="option-style-btn tap-response-style-btn"
              data-action="click->option-style#open"
              title="${esc(t("card.style_option"))}">🎨</button>
      <button type="button" class="tap-response-delete"
              data-action="click->card-editor#deleteResponse"
              title="${esc(t("card.remove_response", { default: "Remove this answer" }))}"
              aria-label="${esc(t("card.remove_response", { default: "Remove this answer" }))}">×</button>
    </div>`
}

// The whole strip, from a resolved TapScales list (lib/tap_scales.js#resolveResponses).
//
// This is the twin of shared/_tap_responses.html.erb and has to agree with it:
// the server renders the strip once and this rebuilds it on every type switch
// and scale change, so an affordance left here reappears the moment a creator
// touches the card. The ＋ was removed from both together — "Answers per
// statement" in the settings panel is the one control for how many there are.
export function tapResponseStripHtml(responses) {
  return `
    <div class="rotate-actions${fans(responses.length) ? " rotate-actions--fan" : ""}"
         data-tap-responses
         data-response-count="${responses.length}">
      ${responses.map((r, i) => tapResponseHtml(r, i)).join("")}
    </div>`
}
