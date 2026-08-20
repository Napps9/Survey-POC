// Placeholder answer options for a card of each type, and which types show an
// option list versus a pair of scale labels versus nothing at all.
//
// This existed twice — in type_panel_controller and, under a comment claiming
// to mirror it, in add_question_controller. The second copy was missing `nps`
// and `prioritise`, so picking Prioritise from "Add question" produced a card
// with no options at all: the modal showed no option rows, `_collectCard`
// emitted no `options`, and the creator got an empty question.
//
// Every type a creator can pick must appear below, including the ones that
// deliberately have no options — an explicit `[]` is distinguishable from an
// omission, which is the lesson from the consent_gate builder (BUG-016).
// test/lib/js_constant_parity_test.rb asserts the coverage against
// CardTypes.pickable.
export const DEFAULT_OPTIONS = {
  range:            [ "Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree" ],
  nps:              [ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" ],
  rating:           [ "Poor", "Fair", "Good", "Great", "Excellent" ],
  multiple_choice:  [ "Option A", "Option B", "Option C" ],
  select_many:      [ "Option A", "Option B", "Option C", "Option D", "Option E" ],
  prioritise:       [ "Option A", "Option B", "Option C", "Option D" ],
  yes_no:           [ "Yes", "No" ],
  select_one_grid:  [ "A", "B", "C", "D" ],
  select_many_grid: [ "A", "B", "C", "D" ],
  tap_card:         [ "Statement 1", "Statement 2", "Statement 3", "Statement 4", "Statement 5" ],
  scenario:         [ "Option A", "Option B" ],
  open_ended:       [],
  welcome_card:     [],
  token_checkpoint: [],
  consent_gate:     []
}

// The table above is the ENGLISH FALLBACK. Placeholder options are card
// content, not chrome — they get saved into the deck the moment the creator
// keeps them — so they follow the Verto's default locale, not the UI locale.
// The editor page emits them resolved for that locale as a `card-defaults`
// JSON blob (see surveys/show + the `defaults:` locale namespace, which
// mirrors this table across all 19 files). Always go through this function;
// reach into DEFAULT_OPTIONS directly only for a deliberately-English fixture.
// Parsed per call, not cached at module level: the module survives Turbo
// navigations but the blob is per-survey (each Verto has its own default
// locale), so a cache here would bleed one Verto's language into the next.
// Calls are rare (a type switch), the blob is tiny.
function localizedDefaults() {
  try {
    return JSON.parse(document.getElementById("card-defaults")?.textContent || "null")
  } catch (_) {
    return null
  }
}

export function defaultOptionsFor(type) {
  const blob = localizedDefaults()
  const v = blob && blob[type]
  if (Array.isArray(v) && v.length) return v.slice()
  return (DEFAULT_OPTIONS[type] || []).slice()
}

// Types whose details form shows an editable list of answer options.
export const OPTION_TYPES = new Set([
  "multiple_choice", "select_many", "prioritise",
  "select_one_grid", "select_many_grid",
  "tap_card", "scenario"
])

// Types whose details form shows min / max scale labels instead of a list.
export const LABEL_TYPES = new Set([ "range", "rating" ])

// The placeholder for the Nth option row (0-based), continuing the same lettered
// sequence the seeded rows use. It used to be `Option ${n + 1}`, so a
// multiple-choice card seeded with "Option A/B/C" carried on "Option 4, Option
// 5…" — two naming schemes in one list, which is what "just for consistency,
// use letters or numbers" was about (18 Aug).
//
// Past Z it doubles up (AA, AB…) rather than falling back to digits, so the
// sequence stays one kind of thing however many options a creator adds.
export function optionPlaceholder(index) {
  let n = Math.max(0, Math.floor(Number(index) || 0))
  let letters = ""
  do {
    letters = String.fromCharCode(65 + (n % 26)) + letters
    n = Math.floor(n / 26) - 1
  } while (n >= 0)
  return `Option ${letters}`
}
