// JS twin of app/lib/option_icon_library.rb for option-row markup built
// client-side (type switches, newly added options). The server renders icons
// inline into the ERB; markup built in the browser used to silently omit
// them, so switching a card's answer type visually stripped every icon until
// the next full reload.
//
// The keyword→URL map is emitted by the editor page as a JSON island
// (#option-icon-map) — the 54 SVG bodies total ~200KB, so they are fetched
// on demand (module-cached) rather than inlined. Fetch-and-inline (not an
// <img>) keeps the `currentColor` tinting the inline server render gets.

// Mirror of OptionIconLibrary.normalize, including the de-pluralise retry in
// fileFor below.
export function normalize(label) {
  return String(label ?? "")
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9\s]/g, "")
    .replace(/\s+/g, " ")
    .trim()
}

let map = null
export function iconMap() {
  if (map) return map
  const el = document.getElementById("option-icon-map")
  try {
    map = el ? JSON.parse(el.textContent) : {}
  } catch (_e) {
    map = {}
  }
  map.keywords ||= {}
  map.ids ||= {}
  map.emojis ||= {}
  map.fallbacks ||= []
  return map
}

// Twin of OptionIconLibrary.emoji_for — the guarantee that no selection answer
// shows an empty tile. Keyword match first, then a neutral shape cycled by
// position so a deck's rows stay distinct without asserting any meaning.
export function emojiFor(label, index = 0) {
  const { emojis, fallbacks } = iconMap()
  if (!fallbacks.length) return null
  const n = normalize(label)
  return emojis[n] || emojis[n.replace(/s$/, "")] || fallbacks[Math.abs(index) % fallbacks.length]
}

export function emojiInto(tile, label, index = 0) {
  if (!tile || tile.querySelector("svg, .choice-icon-emoji")) return
  const emoji = emojiFor(label, index)
  if (!emoji) return
  const span = document.createElement("span")
  span.className = "choice-icon-emoji"
  span.setAttribute("aria-hidden", "true")
  span.textContent = emoji
  tile.insertAdjacentElement("afterbegin", span)
}

export function urlFor(label) {
  const keywords = iconMap().keywords
  const n = normalize(label)
  if (!n) return null
  return keywords[n] || keywords[n.replace(/s$/, "")] || null
}

const svgCache = {}

async function fetchSvg(url) {
  svgCache[url] ||= fetch(url).then((r) => (r.ok ? r.text() : ""))
  let raw = await svgCache[url]
  if (!raw) return ""
  // Same scrubs as OptionIconLibrary#inline_svg: no <title>, no ids (the same
  // icon can appear twice on a page), decorative markup.
  return raw
    .replace(/<title>[\s\S]*?<\/title>/, "")
    .replace(/\s(?:id|data-name)="[^"]*"/g, "")
    .replace(/<svg\b/, '<svg class="choice-icon-svg" aria-hidden="true" focusable="false"')
}

// Inject the icon for `label` (if any matches) into a tile element, unless
// one is already there. Async and best-effort — icons are decorative.
export async function iconInto(tile, label) {
  if (!tile) return
  injectUrl(tile, urlFor(label))
}

// Inject an explicitly picked icon (per-option `option_styles.icon`) by its
// library id — see OptionIconLibrary#svg_by_id for the server twin.
export async function iconIntoById(tile, id) {
  if (!tile) return
  injectUrl(tile, iconMap().ids[String(id ?? "")] || null)
}

async function injectUrl(tile, url) {
  if (!url) return
  try {
    const svg = await fetchSvg(url)
    if (svg && tile.isConnected && !tile.querySelector("svg, .choice-icon-emoji")) {
      tile.insertAdjacentHTML("afterbegin", svg)
    }
  } catch (_e) {
    // decorative — never let an icon failure break the editor
  }
}

// Icon pass over freshly built option markup, honouring per-option style
// overrides (data-option-icon / data-option-emoji beat the keyword match).
// Rows the server renders keyword-icon-free (prioritise, yes/no) still get the
// emoji fallback — no selection answer should show an empty tile.
export function injectIcons(root) {
  if (!root) return
  const fill = (li, tile, label, keywordOk, index) => {
    if (!tile || tile.querySelector("svg, .choice-icon-emoji")) return
    if (li.dataset.optionIcon) return iconIntoById(tile, li.dataset.optionIcon)
    if (li.dataset.optionEmoji) return
    // The keyword icon is async; the emoji fallback only lands if nothing
    // matched, so it can't race an icon into the same tile.
    if (keywordOk) {
      iconInto(tile, label).then(() => emojiInto(tile, label, index))
      return
    }
    emojiInto(tile, label, index)
  }
  root.querySelectorAll(".choice-list .choice-list-item").forEach((li, i) => {
    const keywordOk = !li.classList.contains("prioritise-item") && !li.closest(".choice-list--yesno")
    fill(li, li.querySelector(".choice-list-tile"), li.querySelector(".pick-text, .choice-list-label")?.textContent, keywordOk, i)
  })
  root.querySelectorAll(".choice-card").forEach((li, i) => {
    fill(li, li.querySelector(".choice-card-bg"), li.querySelector(".choice-label")?.textContent, true, i)
  })
}
