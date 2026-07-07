// Rules of the Game — the "Do's and Don'ts" the Verto generator follows
// (SurveyGenerator::SYSTEM / CARD_RULES and the source "Rules of the Game"
// document), re-expressed as live editor checks. Each check returns a
// traffic-light rating plus a plain-language pointer on how to reach green —
// the Yoast-style analysis the editor renders per card and for the whole Verto.
//
// This module is the single source of truth for the editor's rule thresholds;
// survey_editor_controller only reads the DOM and paints the result.
import { t } from "lib/i18n"

export const GREEN = "green"
export const YELLOW = "yellow"
export const RED = "red"
export const INFO = "info" // a non-scoring tip (e.g. "consider a midway break")

// ── Thresholds, straight from the Rules of the Game ──────────────────────
// Per-card answer-count rule, by card type. {min,max} is the green range;
// `even` grids must have an even count (the doc counts the "Other" box);
// `odd` types must have an odd count — image lists so a compact 3-or-5 row
// scans well, ranges so the slider always has a true centre step to rest a
// genuinely neutral option on; `exact` pins a fixed count. Types absent
// here carry no count rule.
const COUNT_RULES = {
  multiple_choice:  { min: 3, max: 5, odd: true },       // §3 image list
  select_many:      { min: 3, max: 5, odd: true },       // §3 image list
  range:            { min: 3, max: 5, odd: true },       // §3 range
  rating:           { min: 3, max: 5 },                  // §3 rating
  tap_card:         { min: 5, max: 8 },                  // §3 tap card
  prioritise:       { min: 4, max: 5 },                  // §3 prioritise
  select_one_grid:  { min: 4, max: 10, even: true },     // §3 image grid
  select_many_grid: { min: 4, max: 10, even: true },     // §3 image grid
  nps:              { exact: 11 }                        // §3 nps: 0–10
}

// §2 — answer label budget per card type. Image lists and Prioritise rows
// get 30, grid tiles and scale labels stay at a scannable 20, and Tap
// statements read as full mini-statements so they get 40.
const OPTION_LIMITS = {
  multiple_choice: 30, select_many: 30, prioritise: 30,
  select_one_grid: 20, select_many_grid: 20,
  range: 20, rating: 20, nps: 20,
  tap_card: 40
}

// §2 — TEXT_MIN is the target floor shown in copy only; short is never flagged.
const TEXT_MIN = 50, TEXT_MAX = 70, TEXT_HARD_MAX = 100
const CARD_MIN = 12, CARD_MAX = 16, CARD_YELLOW_MIN = 8   // §1.1 (cards, incl. welcome)
const PACE_TIP_AT = 15                                    // §1.5
const RUN_MAX = 2                                         // §1.4
const WELCOME_MAX = 1                                     // §1.3

// Score deductions per non-green check, and the green/amber/red cut-offs —
// one amber leaves a card green (like Yoast), a red always drops it below.
const CARD_PENALTY = { [RED]: 40, [YELLOW]: 15, [GREEN]: 0, [INFO]: 0 }
const VERTO_PENALTY = { [RED]: 25, [YELLOW]: 12, [GREEN]: 0, [INFO]: 0 }
const GREEN_AT = 80, YELLOW_AT = 50

// Friendly answer-type names for the diversity pointer.
const TYPE_LABEL = {
  multiple_choice: "Pick one (list)", select_many: "Select many (list)",
  select_one_grid: "Pick one (grid)", select_many_grid: "Select many (grid)",
  tap_card: "Tap", range: "Range", rating: "Rating", nps: "NPS",
  yes_no: "Yes / No", open_ended: "Freeform", welcome_card: "Welcome",
  token_checkpoint: "Points Checkpoint", prioritise: "Prioritise"
}

// Mirrors CardTypes::NON_QUESTION_TYPES (app/lib/card_types.rb).
const NON_QUESTION_TYPES = [ "welcome_card", "token_checkpoint" ]
const isQuestion = (c) => !NON_QUESTION_TYPES.includes(c && c.type ? c.type : "")
export const typeLabel = (ty) => TYPE_LABEL[ty] || (ty || "").replace(/_/g, " ")
const cleanOptions = (c) => (Array.isArray(c.options) ? c.options : [])
  .map((o) => (o || "").toString().trim()).filter(Boolean)
const check = (id, rating, text) => ({ id, rating, text })

function rate(score) {
  return score >= GREEN_AT ? GREEN : score >= YELLOW_AT ? YELLOW : RED
}

// ── Per-card analysis ────────────────────────────────────────────────────
// `card` is { type, text, description, options, allowOther }. Returns
// { score, rating, checks } — or null for a welcome card (not a question,
// not scored, per §1.3).
export function analyzeCard(card) {
  if (!isQuestion(card)) return null

  const checks = [ lengthCheck(card) ]

  const countRule = COUNT_RULES[card.type]
  if (countRule) checks.push(countCheck(card, countRule))

  const optionCheck = optionLengthCheck(card)
  if (optionCheck) checks.push(optionCheck)

  const penalty = checks.reduce((s, c) => s + (CARD_PENALTY[c.rating] || 0), 0)
  const score = Math.max(0, 100 - penalty)
  return { score, rating: rate(score), checks }
}

// §2 — question text targets 50–70 chars; text + any description ≤ 100.
// Short text is never flagged — only empty, over-target, or over the cap.
function lengthCheck(card) {
  const tLen = (card.text || "").trim().length
  const total = tLen + (card.description || "").trim().length
  if (tLen === 0) return check("length", RED, t("editor.rules.length_empty"))
  if (total > TEXT_HARD_MAX) return check("length", RED, t("editor.rules.length_over", { n: total, max: TEXT_HARD_MAX }))
  if (tLen <= TEXT_MAX) return check("length", GREEN, t("editor.rules.length_ok", { min: TEXT_MIN, max: TEXT_MAX }))
  return check("length", YELLOW, t("editor.rules.length_long", { n: total, min: TEXT_MIN, max: TEXT_MAX }))
}

// §3 — number of answer choices (even grids incl. the Other box; odd lists
// and ranges; exact-count scales).
function countCheck(card, rule) {
  const isGrid = card.type === "select_one_grid" || card.type === "select_many_grid"
  let n = cleanOptions(card).length
  // Rating is a fixed 5-star visual and the editor exposes only its two end
  // caption fields, so the DOM never carries one option per step. Score it
  // as the 5 points it always renders, not the caption count.
  if (card.type === "rating") n = 5
  if (isGrid && card.allowOther) n += 1 // the Other box counts toward the grid

  if (rule.exact != null) {
    return n === rule.exact
      ? check("count", GREEN, t("editor.rules.count_exact_ok", { n }))
      : check("count", YELLOW, t("editor.rules.count_exact", { n, exact: rule.exact }))
  }

  const { min, max, even, odd } = rule
  if (n < min) return check("count", n >= min - 1 ? YELLOW : RED, t("editor.rules.count_few", { n, min, max }))
  if (n > max) return check("count", n <= max + 1 ? YELLOW : RED, t("editor.rules.count_many", { n, max }))
  if (even && n % 2 !== 0) return check("count", YELLOW, t("editor.rules.count_even", { n }))
  if (odd && n % 2 === 0) {
    const key = card.type === "range" ? "editor.rules.count_odd" : "editor.rules.count_odd_list"
    return check("count", YELLOW, t(key, { n }))
  }
  return check("count", GREEN, t("editor.rules.count_ok", { n, min, max }))
}

// §2 — answer labels within their per-type budget (see OPTION_LIMITS).
function optionLengthCheck(card) {
  const limit = OPTION_LIMITS[card.type]
  if (!limit) return null
  const opts = cleanOptions(card)
  if (!opts.length) return null
  const over = opts.filter((o) => o.length > limit)
  if (!over.length) return check("option", GREEN, t("editor.rules.option_ok", { max: limit }))
  const worst = over.reduce((a, b) => (b.length > a.length ? b : a))
  const rating = worst.length > limit * 1.5 ? RED : YELLOW
  const label = worst.length > 24 ? worst.slice(0, 23) + "…" : worst
  return check("option", rating, t("editor.rules.option_long", { opt: label, max: limit }))
}

// ── Whole-Verto analysis ─────────────────────────────────────────────────
// `cards` is an ordered array of the same card objects. Returns
// { score, rating, checks, tally, cardCount, questionCount }.
export function analyzeVerto(cards) {
  const list = Array.isArray(cards) ? cards : []
  const checks = []

  // §1.1 — card count. The scored unit is CARDS (welcome included), per the
  // Rules of the Game table "12–16 inc. welcome/end".
  const cardCount = list.length
  checks.push(cardCountCheck(cardCount))

  // §1.2 — the weighted question count (a Tap card counts as its statements)
  // no longer drives the score, but still informs the pace tip below.
  const questionCount = list.reduce((sum, c) => {
    if (!isQuestion(c)) return sum
    return sum + (c.type === "tap_card" ? Math.max(cleanOptions(c).length, 1) : 1)
  }, 0)

  // §1.4 — answer diversity: never more than 2 of a type in a row.
  checks.push(varietyCheck(list))

  // §1.3 — at most one welcome card. Counted by type: a token checkpoint is
  // also a non-question, but it isn't a welcome card.
  const welcomes = list.filter((c) => c && c.type === "welcome_card").length
  if (welcomes > WELCOME_MAX) checks.push(check("welcome", RED, t("editor.rules.welcome_many", { n: welcomes })))

  // §1.5 — a long Verto benefits from a midway break (a tip, not a penalty).
  if (cardCount >= PACE_TIP_AT || questionCount >= PACE_TIP_AT) checks.push(check("static", INFO, t("editor.rules.static_tip")))

  // Roll the per-card scores into the Verto score, then apply Verto-level hits.
  const cardResults = list.filter(isQuestion).map(analyzeCard).filter(Boolean)
  const cardsAvg = cardResults.length
    ? cardResults.reduce((s, r) => s + r.score, 0) / cardResults.length
    : 100
  const penalty = checks.reduce((s, c) => s + (VERTO_PENALTY[c.rating] || 0), 0)
  const score = Math.max(0, Math.round(cardsAvg - penalty))

  const tally = { green: 0, yellow: 0, red: 0 }
  cardResults.forEach((r) => { tally[r.rating] += 1 })

  return { score, rating: rate(score), checks, tally, cardCount, questionCount }
}

// §1.1 — green 12–16 cards, yellow 8–11, red under 8 or over 16.
function cardCountCheck(n) {
  if (n >= CARD_MIN && n <= CARD_MAX) return check("c_count", GREEN, t("editor.rules.ccount_ok", { n, min: CARD_MIN, max: CARD_MAX }))
  if (n > CARD_MAX) return check("c_count", RED, t("editor.rules.ccount_many", { n, max: CARD_MAX }))
  if (n >= CARD_YELLOW_MIN) return check("c_count", YELLOW, t("editor.rules.ccount_few", { n, min: CARD_MIN, max: CARD_MAX }))
  return check("c_count", RED, t("editor.rules.ccount_min", { n, min: CARD_MIN }))
}

function varietyCheck(cards) {
  const types = cards.filter(isQuestion).map((c) => c.type)
  let runType = null, runLen = 0, worst = null
  types.forEach((ty) => {
    runLen = ty === runType ? runLen + 1 : 1
    runType = ty
    if (runLen > RUN_MAX && (!worst || runLen > worst.len)) worst = { type: ty, len: runLen }
  })
  return worst
    ? check("variety", RED, t("editor.rules.variety_run", { type: typeLabel(worst.type), n: worst.len }))
    : check("variety", GREEN, t("editor.rules.variety_ok"))
}
