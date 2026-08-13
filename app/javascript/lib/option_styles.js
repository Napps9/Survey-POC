// Client mirror of the per-option visual overrides (`option_styles` on
// choice-shaped cards): ApplicationHelper#option_tile_style / #option_tile_icon
// render them server-side; this module keeps the editor's live repaint and
// rebuilt markup pixel-identical. A style is {color, icon, emoji} (any subset)
// carried as data-option-* attributes on the option row — serialize() reads
// the rows back, so DOM order IS the positional alignment with `options`.
import { lighten } from "lib/brand_palette"
import { iconInto, iconIntoById, emojiInto } from "lib/option_icons"
import { tapGlyphSvg } from "lib/tap_response_templates"

// Same gradient shape as the stock choice-bg-N classes, from the picked hex.
export function tileStyle(style) {
  const hex = style && style.color
  if (!hex) return ""
  return `background:linear-gradient(135deg, ${lighten(hex, 0.18)}, ${hex});`
}

export function styleFromRow(li) {
  if (!li) return null
  const s = {}
  if (li.dataset.optionColor) s.color = li.dataset.optionColor
  if (li.dataset.optionIcon) s.icon = li.dataset.optionIcon
  if (li.dataset.optionEmoji) s.emoji = li.dataset.optionEmoji
  return Object.keys(s).length ? s : null
}

export function writeStyleToRow(li, style) {
  if (!li) return
  for (const key of ["optionColor", "optionIcon", "optionEmoji"]) delete li.dataset[key]
  if (style?.color) li.dataset.optionColor = style.color
  if (style?.icon) li.dataset.optionIcon = style.icon
  if (style?.emoji) li.dataset.optionEmoji = style.emoji
}

// Types whose bare tiles deliberately carry no keyword-matched icon — the
// server renders them icon-free, so the fallback must too.
function keywordFallback(li) {
  return !(li.classList.contains("prioritise-item") || li.closest(".choice-list--yesno"))
}

// A tap card's response wears its style differently from an option row: the
// colour is the ring (or the pill border) rather than a tile gradient, and the
// mark sits inside the button. It arrives here because it carries the same
// data-option-* attributes and shares the 🎨 popover — see
// option_style_controller#open — so this is where the two shapes part.
function repaintTapResponse(el, style) {
  const slot = el.querySelector(".rotate-action-btn")
  if (!slot) return
  if (style?.color) {
    el.style.setProperty("--tap-response-color", style.color)
  } else {
    el.style.removeProperty("--tap-response-color")
  }
  slot.querySelectorAll("svg, img, .choice-icon-emoji").forEach((n) => n.remove())
  if (style?.icon) {
    iconIntoById(slot, style.icon)
  } else if (style?.emoji) {
    const span = document.createElement("span")
    span.className = "choice-icon-emoji"
    span.setAttribute("aria-hidden", "true")
    span.textContent = style.emoji
    slot.appendChild(span)
  } else {
    // Nothing explicit left — fall back to the scale's own glyph, which is what
    // the server does (ApplicationHelper#tap_response_mark), so a cleared style
    // returns the response to the artwork its preset gave it rather than to a
    // keyword guess at its label.
    const glyph = el.dataset.responseGlyph
    if (glyph) {
      slot.insertAdjacentHTML("afterbegin", tapGlyphSvg(glyph))
    } else {
      const label = el.querySelector("[data-tap-response-label]")?.textContent
      const index = [ ...(el.parentElement?.children || []) ].indexOf(el)
      emojiInto(slot, label, index)
    }
  }
}

// Repaint one option row to match a style (or its absence): tile background,
// then the icon slot with the same precedence as the server — explicit icon,
// emoji, keyword match, nothing.
export function repaintRow(li, style) {
  if (li.matches?.("[data-tap-response]")) return repaintTapResponse(li, style)

  const tile = li.querySelector(".choice-list-tile, .choice-card-bg")
  if (!tile) return
  tile.style.background = style?.color
    ? `linear-gradient(135deg, ${lighten(style.color, 0.18)}, ${style.color})`
    : ""
  tile.querySelectorAll("svg, .choice-icon-emoji").forEach((n) => n.remove())
  if (style?.icon) {
    iconIntoById(tile, style.icon)
  } else if (style?.emoji) {
    const span = document.createElement("span")
    span.className = "choice-icon-emoji"
    span.setAttribute("aria-hidden", "true")
    span.textContent = style.emoji
    tile.insertAdjacentElement("afterbegin", span)
  } else {
    // Nothing explicit left — fall back exactly as the server does, ending in
    // an emoji so a cleared style never leaves an empty tile.
    const label = li.querySelector(".pick-text, .choice-list-label, .choice-label")?.textContent
    const index = [ ...(li.parentElement?.children || []) ].indexOf(li)
    if (keywordFallback(li)) {
      iconInto(tile, label).then(() => emojiInto(tile, label, index))
    } else {
      emojiInto(tile, label, index)
    }
  }
}
