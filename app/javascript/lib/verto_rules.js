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
// `odd` (range) must have an odd count so the slider always has a true
// centre step to rest a genuinely neutral option on; `exact` pins a fixed
// count. Types absent here carry no count rule.
const COUNT_RULES = {
  multiple_choice:  { min: 3, max: 5 },                  // rule 6
  select_many:      { min: 3, max: 5 },                  // rule 6
  range:            { min: 3, max: 5, odd: true },       // rule 6
  rating:           { min: 3, max: 5 },                  // rule 6
  tap_card:         { min: 3, max: 5 },                  // rule 2 (3–5 cards)
  select_one_grid:  { min: 4, max: 10, even: true },     // rule 7
  select_many_grid: { min: 4, max: 10, even: true },     // rule 7
  nps:              { exact: 5 }
}

const TEXT_MIN = 50, TEXT_MAX = 70, TEXT_HARD_MAX = 100  // rules 8 & 9
const OPTION_MAX = 20, TAP_OPTION_MAX = 30               // rule 10
const Q_MIN = 10, Q_MAX = 15                             // rule 1
const RUN_MAX = 2                                        // rules 2 & 5
const WELCOME_MAX = 1                                    // rule 4

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
  yes_no: "Yes / No", open_ended: "Freeform", welcome_card: "Welcome"
}

const isQuestion = (c) => (c && c.type ? c.type : "") !== "welcome_card"
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
// not scored, per rule 2).
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

// Rules 8 & 9 — question text 50–70 chars; text + any description ≤ 100.
function lengthCheck(card) {
  const tLen = (card.text || "").trim().length
  const total = tLen + (card.description || "").trim().length
  if (tLen === 0) return check("length", RED, t("editor.rules.length_empty"))
  if (total > TEXT_HARD_MAX) return check("length", RED, t("editor.rules.length_over", { n: total, max: TEXT_HARD_MAX }))
  if (tLen >= TEXT_MIN && tLen <= TEXT_MAX) return check("length", GREEN, t("editor.rules.length_ok", { min: TEXT_MIN, max: TEXT_MAX }))
  if (tLen < TEXT_MIN) return check("length", YELLOW, t("editor.rules.length_short", { n: tLen, min: TEXT_MIN, max: TEXT_MAX }))
  return check("length", YELLOW, t("editor.rules.length_long", { n: total, min: TEXT_MIN, max: TEXT_MAX }))
}

// Rules 6 & 7 — number of answer choices (+ even grids, incl. the Other box).
function countCheck(card, rule) {
  const isGrid = card.type === "select_one_grid" || card.type === "select_many_grid"
  let n = cleanOptions(card).length
  // Rating is a fixed 5-point star scale — its two labels are just the end
  // captions ("Poor" … "Excellent"), not the answer count. Score it as the
  // 5 points it always renders, so it isn't perpetually flagged "only 2".
  if (card.type === "rating") n = 5
  if (isGrid && card.allowOther) n += 1 // rule 7: the Other box counts

  if (rule.exact != null) {
    return n === rule.exact
      ? check("count", GREEN, t("editor.rules.count_exact_ok", { n }))
      : check("count", YELLOW, t("editor.rules.count_exact", { n, exact: rule.exact }))
  }

  const { min, max, even, odd } = rule
  if (n < min) return check("count", n >= min - 1 ? YELLOW : RED, t("editor.rules.count_few", { n, min, max }))
  if (n > max) return check("count", n <= max + 1 ? YELLOW : RED, t("editor.rules.count_many", { n, max }))
  if (even && n % 2 !== 0) return check("count", YELLOW, t("editor.rules.count_even", { n }))
  if (odd && n % 2 === 0) return check("count", YELLOW, t("editor.rules.count_odd", { n }))
  return check("count", GREEN, t("editor.rules.count_ok", { n, min, max }))
}

// Rule 10 — answer labels ≤ 20 chars (≤ 30 for the longer Tap statements).
function optionLengthCheck(card) {
  const opts = cleanOptions(card)
  if (!opts.length || !COUNT_RULES[card.type]) return null
  const limit = card.type === "tap_card" ? TAP_OPTION_MAX : OPTION_MAX
  const over = opts.filter((o) => o.length > limit)
  if (!over.length) return check("option", GREEN, t("editor.rules.option_ok", { max: limit }))
  const worst = over.reduce((a, b) => (b.length > a.length ? b : a))
  const rating = worst.length > limit * 1.5 ? RED : YELLOW
  const label = worst.length > 24 ? worst.slice(0, 23) + "…" : worst
  return check("option", rating, t("editor.rules.option_long", { opt: label, max: limit }))
}

// ── Whole-Verto analysis ─────────────────────────────────────────────────
// `cards` is an ordered array of the same card objects. Returns
// { score, rating, checks, tally, questionCount }.
export function analyzeVerto(cards) {
  const list = Array.isArray(cards) ? cards : []
  const checks = []

  // Rules 1 & 2 — question count (Range = 1; a Tap card counts as its cards).
  const questionCount = list.reduce((sum, c) => {
    if (!isQuestion(c)) return sum
    return sum + (c.type === "tap_card" ? Math.max(cleanOptions(c).length, 1) : 1)
  }, 0)
  checks.push(questionCountCheck(questionCount))

  // Rules 2 & 5 — answer diversity: never more than 2 of a type in a row.
  checks.push(varietyCheck(list))

  // Rule 4 — at most one welcome card.
  const welcomes = list.filter((c) => !isQuestion(c)).length
  if (welcomes > WELCOME_MAX) checks.push(check("welcome", RED, t("editor.rules.welcome_many", { n: welcomes })))

  // Rule 3 — a long Verto benefits from a midway break (a tip, not a penalty).
  if (questionCount >= Q_MAX) checks.push(check("static", INFO, t("editor.rules.static_tip")))

  // Roll the per-card scores into the Verto score, then apply Verto-level hits.
  const cardResults = list.filter(isQuestion).map(analyzeCard).filter(Boolean)
  const cardsAvg = cardResults.length
    ? cardResults.reduce((s, r) => s + r.score, 0) / cardResults.length
    : 100
  const penalty = checks.reduce((s, c) => s + (VERTO_PENALTY[c.rating] || 0), 0)
  const score = Math.max(0, Math.round(cardsAvg - penalty))

  const tally = { green: 0, yellow: 0, red: 0 }
  cardResults.forEach((r) => { tally[r.rating] += 1 })

  return { score, rating: rate(score), checks, tally, questionCount }
}

function questionCountCheck(n) {
  if (n >= Q_MIN && n <= Q_MAX) return check("q_count", GREEN, t("editor.rules.qcount_ok", { n, min: Q_MIN, max: Q_MAX }))
  if (n > Q_MAX) return check("q_count", RED, t("editor.rules.qcount_many", { n, max: Q_MAX }))
  if (n >= Q_MIN - 2) return check("q_count", YELLOW, t("editor.rules.qcount_few", { n, min: Q_MIN, max: Q_MAX }))
  return check("q_count", RED, t("editor.rules.qcount_min", { n, min: Q_MIN }))
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
