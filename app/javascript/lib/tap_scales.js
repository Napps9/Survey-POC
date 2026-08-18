// Client mirror of TapScales (app/lib/tap_scales.rb + config/tap_scales.yml) —
// a tap card's response scale, the set of answers a respondent chooses between
// on each swipe statement.
//
// The editor rebuilds a card's response strip client-side on a type switch and
// on every preset change, so it needs the same table the server renders from.
// test/lib/js_constant_parity_test.rb asserts the two agree; the direction
// arithmetic is duplicated rather than shared because the player computes it on
// every commit and cannot wait for a round trip.

// ENGLISH FALLBACK. Preset labels are card CONTENT the moment a creator keeps
// them, so they follow the Verto's language, not the UI's — the editor page
// emits them resolved for that locale as a `tap-scales` JSON blob. Go through
// presetFor(); reach in here only for a deliberately-English fixture.
export const TAP_PRESETS = {
  2: [
    { key: "no",  label: "No",  glyph: "no",  color: "#D80027" },
    { key: "yes", label: "Yes", glyph: "yes", color: "#01EACB" }
  ],
  3: [
    { key: "no",     label: "No",     glyph: "no",     color: "#D80027" },
    { key: "unsure", label: "Unsure", glyph: "unsure", color: "#F5A623" },
    { key: "yes",    label: "Yes",    glyph: "yes",    color: "#01EACB" }
  ],
  4: [
    { key: "strongly_disagree", label: "Strongly disagree", glyph: "no",  strong: true, color: "#D80027" },
    { key: "disagree",          label: "Disagree",          glyph: "no",                color: "#F0663F" },
    { key: "agree",             label: "Agree",             glyph: "yes",               color: "#4FBF9F" },
    { key: "strongly_agree",    label: "Strongly agree",    glyph: "yes", strong: true, color: "#01EACB" }
  ],
  5: [
    { key: "strongly_disagree", label: "Strongly disagree", emoji: "\u2764\ufe0f", color: "#D80027" },
    { key: "disagree",          label: "Disagree",          emoji: "\ud83d\ude41", color: "#F0663F" },
    { key: "neutral",           label: "Neutral",           emoji: "\ud83d\ude10", color: "#F5A623" },
    { key: "agree",             label: "Agree",             emoji: "\ud83d\ude42", color: "#4FBF9F" },
    { key: "strongly_agree",    label: "Strongly agree",    emoji: "\ud83d\udc9a", color: "#01EACB" }
  ],
  6: [
    { key: "strongly_disagree", label: "Strongly disagree", emoji: "\u2764\ufe0f", color: "#D80027" },
    { key: "disagree",          label: "Disagree",          emoji: "\ud83d\ude41", color: "#F0663F" },
    { key: "slightly_disagree", label: "Slightly disagree", emoji: "\ud83d\ude15", color: "#F7B32B" },
    { key: "slightly_agree",    label: "Slightly agree",    emoji: "\ud83d\ude42", color: "#9DC66B" },
    { key: "agree",             label: "Agree",             emoji: "\ud83d\ude0a", color: "#4FBF9F" },
    { key: "strongly_agree",    label: "Strongly agree",    emoji: "\ud83d\udc9a", color: "#01EACB" }
  ]
}

export const DEFAULT_TAP_COUNT = 3
export const MIN_TAP_RESPONSES = 2
export const MAX_TAP_RESPONSES = 6
export const TAP_FAN_THRESHOLD = 5

// The arc the wide scales are laid out on — see TapScales::FAN_* in Ruby.
export const FAN_START = 232
export const FAN_END = -52
const FAN_CX = 50, FAN_CY = 57.5, FAN_RX = 30, FAN_RY = 22

// Parsed per call, not cached at module level: the module survives Turbo
// navigations but the blob is per-survey (each Verto has its own default
// locale), so a cache would bleed one Verto's language into the next. Same
// reasoning as lib/default_options.js.
function localizedScales() {
  try {
    return JSON.parse(document.getElementById("tap-scales")?.textContent || "null")
  } catch (_) {
    return null
  }
}

// The seed set for a count, in the Verto's language where the page provides it.
// Deep-copied — the caller hands these to a creator to edit.
export function presetFor(count) {
  const blob = localizedScales()
  const list = (blob && blob.presets && blob.presets[count]) || TAP_PRESETS[count]
  return Array.isArray(list) ? list.map(r => ({ ...r })) : []
}

export function presetCounts() {
  return Object.keys(TAP_PRESETS).map(Number).sort((a, b) => a - b)
}

// Every key any preset defines, so a card storing a bare key still resolves a
// glyph and a colour. First definition wins — the presets agree on the ones
// they share.
export function defaultsForKey(key) {
  for (const count of presetCounts()) {
    const hit = TAP_PRESETS[count].find(r => r.key === key)
    if (hit) return hit
  }
  return null
}

// Five and up fan out over the photo; four and under stay a row of circles.
export function fans(count) {
  return Number(count) >= TAP_FAN_THRESHOLD
}

// [x, y] percentages for one response on the fan. Mirrors
// TapScales.fan_position — most-negative at the bottom left, the middle at the
// apex, most-positive at the bottom right.
//
// Spaced by ROW, not by angle: a circle's vertical projection bunches at its
// apex, so an even angle step left a five-point scale's rows 14.84% then
// 24.50% of the card apart and the two "strongly" pins hung below the rest.
// `depth` (0 at the apex, 1 at the ends) is linear in the index, so spacing y
// linearly in it makes every row gap equal; x comes back off the ellipse so the
// pins still describe an arc. See the Ruby for the full note.
const FAN_APEX_Y = FAN_CY - FAN_RY
const FAN_END_Y  = FAN_CY - FAN_RY *
  (Math.sin((FAN_START * Math.PI) / 180) + Math.sin((FAN_END * Math.PI) / 180)) / 2

export function fanPosition(index, count) {
  const n = Number(count)
  if (!(n >= 2)) return [ FAN_CX, FAN_CY ]

  const t     = index / (n - 1)
  const depth = Math.abs(2 * t - 1)
  const y     = FAN_APEX_Y + (FAN_END_Y - FAN_APEX_Y) * depth

  const sin = Math.max(-1, Math.min(1, (FAN_CY - y) / FAN_RY))
  const cos = Math.sqrt(Math.max(1 - sin * sin, 0)) * (t < 0.5 ? -1 : 1)

  return [
    Math.round((FAN_CX + FAN_RX * cos) * 100) / 100,
    Math.round(y * 100) / 100
  ]
}

// Which way the card flies when this response is chosen. The scale is ordered
// most-negative first, so the left half exits left and the right half exits
// right; the exact middle of an odd scale exits upward, which is what the
// 3-point scale has always done with Unsure.
export function directionFor(index, count) {
  const middle = (Number(count) - 1) / 2
  if (index === middle) return "up"
  return index < middle ? "left" : "right"
}

// The inverse, for the drag gesture: a fling can only express three intents, so
// it commits the most extreme response on that side (and the middle one, on an
// odd scale, for a fling upward). Tapping is how a respondent picks the ones in
// between. null means the gesture has no answer to give — an upward fling on an
// even scale — and the card snaps back.
export function indexForDirection(direction, count) {
  const n = Number(count)
  if (!(n >= MIN_TAP_RESPONSES)) return null
  if (direction === "left") return 0
  if (direction === "right") return n - 1
  if (direction === "up") return n % 2 === 1 ? (n - 1) / 2 : null
  return null
}

// A card's stored set, or null when it has none worth honouring. Deliberately
// strict, and identical to TapScales.stored_responses: a malformed or
// out-of-bounds array falls back to the 3-point scale rather than rendering a
// card with one button or nine.
export function storedResponses(list) {
  if (!Array.isArray(list)) return null
  const valid = list.filter(r => r && typeof r === "object" && /^[a-z0-9_]{1,32}$/.test(String(r.key || "")))
  if (valid.length !== list.length) return null
  if (valid.length < MIN_TAP_RESPONSES || valid.length > MAX_TAP_RESPONSES) return null
  return valid
}

// The resolved, ordered response set for rendering — preset defaults filled in
// behind whatever the card stores. Mirrors TapScales.for_card minus the
// translation layer, which only the server render needs.
export function resolveResponses(list) {
  const stored = storedResponses(list) || presetFor(DEFAULT_TAP_COUNT)
  const count = stored.length
  const isFan = fans(count)
  return stored.map((entry, i) => {
    const fallback = defaultsForKey(String(entry.key)) || {}
    const [ x, y ] = fanPosition(i, count)
    return {
      key:       String(entry.key),
      label:     entry.label || fallback.label || String(entry.key),
      icon:      entry.icon || null,
      emoji:     entry.emoji || fallback.emoji || null,
      glyph:     entry.glyph || fallback.glyph || null,
      color:     entry.color || fallback.color,
      strong:    entry.strong === undefined ? !!fallback.strong : !!entry.strong,
      index:     i,
      direction: directionFor(i, count),
      fan:       isFan,
      x, y
    }
  })
}
