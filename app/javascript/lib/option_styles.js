// Client mirror of the per-option visual overrides (`option_styles` on
// choice-shaped cards): ApplicationHelper#option_tile_style / #option_tile_icon
// render them server-side; this module keeps the editor's live repaint and
// rebuilt markup pixel-identical. A style is {color, icon, emoji} (any subset)
// carried as data-option-* attributes on the option row — serialize() reads
// the rows back, so DOM order IS the positional alignment with `options`.
import { lighten } from "lib/brand_palette"
import { iconInto, iconIntoById, emojiInto } from "lib/option_icons"

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

// Repaint one option row to match a style (or its absence): tile background,
// then the icon slot with the same precedence as the server — explicit icon,
// emoji, keyword match, nothing.
export function repaintRow(li, style) {
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
