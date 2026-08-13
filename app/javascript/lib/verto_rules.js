import { ROUTABLE_TYPES } from "lib/routable_types"
import { isPaged } from "lib/paged_types"
import { isQuestionType } from "lib/question_types"
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
// scans well; `exact` pins a fixed count. Types absent here carry no count
// rule.
const COUNT_RULES = {
  multiple_choice:  { min: 3, max: 5, odd: true },       // §3 image list
  select_many:      { min: 3, max: 5, odd: true },       // §3 image list
  // A range is ALWAYS a 5-point scale (Survey::RANGE_POINTS), enforced on
  // save by Survey#enforce_range_scale — so the slider always has a true
  // centre to rest a genuinely neutral option on, and answers compare card to
  // card. Scoring it as a 3–5 span would tell a creator a 3-point scale is
  // fine when the server is about to make it 5.
  range:            { exact: 5 },                        // §3 range
  rating:           { min: 3, max: 5 },                  // §3 rating
  tap_card:         { min: 5, max: 8 },                  // §3 tap card
  prioritise:       { min: 4, max: 5 },                  // §3 prioritise
  select_one_grid:  { min: 4, max: 10, even: true },     // §3 image grid
  select_many_grid: { min: 4, max: 10, even: true },     // §3 image grid
  nps:              { exact: 11 },                       // §3 nps: 0–10
  // A scenario's answer options are the book's final choice — 2, occasionally
  // 3, never multiple_choice's odd-3/5 list rule (this isn't a list, it's a
  // decision point).
  scenario:         { min: 2, max: 3 }
}

// Scenario narrative pages — enough to feel like a story, not so many it
// drags. Checked separately from COUNT_RULES/OPTION_LIMITS (those score the
// answer options; this scores the story pages a scenario also carries).
const PAGE_RULES = { min: 1, max: 5 }
const PAGE_LENGTH_LIMIT = 400

// §2 — answer label budget per card type, and the numbers are the width the
// label actually gets rather than a house style. Measured at 16px by laying
// real text out in the real font, on the phones that matter:
//
//                 grid tile     list row
//   Fold 280        15 chars     19 chars
//   iPhone SE 375   21           30
//   iPhone 15 393   22           32
//   iPhone Max 430  24           35
//   iPad mini 768   26           66
//
// A LIST row spans the answer panel; a GRID tile gets a column of it, so the
// list gets roughly half as much again and the two limits are properly
// different. Lists 40, grids 20, scale captions 20 (they sit side by side
// across the panel), Tap statements 40 (they read as mini-statements).
//
// The grid figure is the only one that is not merely advice. survey_editor
// imports GRID_LABEL_MAX below and stops a tile label being typed past it,
// because the phone player draws the tile at a fixed proportion with one line
// of label under it and 20 characters is what that line holds — past it the
// label wraps, the row grows, and the tile stops matching its neighbours.
// Advising a number and not enforcing it is how a creator ends up shown one
// card on a desktop and a respondent shown another.
//
// A list label is not load-bearing in the same way: the row simply gets
// taller, and the square tile beside it does not depend on the label at all.
// So 40 is shown and scored, never enforced.
//
// Keep in step with app/services/survey_generator.rb, which states these same
// budgets in prose for the model — pinned by
// test/services/survey_generator_rules_test.rb.
const OPTION_LIMITS = {
  multiple_choice: 40, select_many: 40, prioritise: 40,
  select_one_grid: 20, select_many_grid: 20,
  range: 20, rating: 20, nps: 20,
  tap_card: 40, scenario: 40
}

// The hard cap, exported so there is ONE number rather than the editor's copy
// of the rule and the rule. Both grids carry the same limit; asserted in
// test/lib/phone_fit_rule_test.rb so a change to one has to be a change to both.
export const GRID_LABEL_TYPES = [ "select_one_grid", "select_many_grid" ]
export const GRID_LABEL_MAX = OPTION_LIMITS.select_one_grid

// Which types show the creator a live character count while they type. The
// grids, where the count is a hard stop, plus the three list types, where it
// is a nudge. Not every type with a budget: a scale caption or a Tap statement
// has one too, and nobody has asked to be counted while writing those.
export const COUNTED_LABEL_TYPES = [
  ...GRID_LABEL_TYPES, "multiple_choice", "select_many", "prioritise"
]

// The budget for a type, or null where there isn't one (yes_no's fixed pair).
export const optionLabelLimit = (type) => OPTION_LIMITS[type] ?? null

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
  token_checkpoint: "Points Checkpoint", prioritise: "Prioritise",
  scenario: "Scenario"
}

const isQuestion = (c) => isQuestionType(c && c.type ? c.type : "")
export const typeLabel = (ty) => TYPE_LABEL[ty] || (ty || "").replace(/_/g, " ")
const cleanOptions = (c) => (Array.isArray(c.options) ? c.options : [])
  .map((o) => (o || "").toString().trim()).filter(Boolean)
const cleanPages = (c) => (Array.isArray(c.pages) ? c.pages : [])
  .map((p) => (p && p.text ? p.text.toString().trim() : "")).filter(Boolean)
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

  // Demographic cards (the set tail + the opt-in Heritage/Neurodiversity
  // questions) are platform-set instruments, not creator copy: their option
  // lists are fixed taxonomies, so the 3–5-options and label-length advice
  // would mark down every deck that adds them for choices the creator didn't
  // make.
  const countRule = COUNT_RULES[card.type]
  if (countRule && !card.demographic) checks.push(countCheck(card, countRule))

  const optionCheck = card.demographic ? null : optionLengthCheck(card)
  if (optionCheck) checks.push(optionCheck)

  // Same exemption as the two above: a demographic card's options are a fixed
  // platform taxonomy, so telling the creator to trim them is advice they
  // cannot take.
  const phoneCheck = card.demographic ? null : phoneFitCheck(card)
  if (phoneCheck) checks.push(phoneCheck)

  // Every paged type, not just scenario. A no-op today — analyzeCard returns
  // null for non-questions above and consent_gate is one — but the rule being
  // expressed is "does this card have pages", and writing it as a literal type
  // name is what let the editor drop a consent gate's pages on every save.
  if (isPaged(card.type)) {
    checks.push(pageCountCheck(card))
    const pageLenCheck = pageLengthCheck(card)
    if (pageLenCheck) checks.push(pageLenCheck)
  }

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

// Will this image grid work on a phone? COUNT_RULES allows a grid up to ten
// answers, and a creator building on a desktop sees all ten as tiles — but the
// phone player has a fixed budget and buys the imagery back only while the
// answer still fits (player_controller#_fitCard). Past a certain count it
// can't, and the card the respondent gets is not the card the creator was
// shown. Better to say so here than to degrade it silently in front of them.
//
// The numbers are measured, not guessed: a two-column grid at the 16px option
// label, walked across a 280px Fold, a 375 SE, a 393 iPhone and a 430 Max.
// Seven is where the hero image stops fitting on all four; nine is where the
// options themselves start scrolling even with the hero already gone. Counted
// the way countCheck counts, so the Other box is one of them.
//
// Rated INFO — a tip, not a mark against the card (CARD_PENALTY[INFO] is 0).
// Ten answers is inside the Rules of the Game and a creator who wants ten on a
// desktop-first Verto is not doing anything wrong; they just deserve to know
// what the phone will do with it.
const PHONE_HERO_LIMIT = 7    // at or above this, a phone drops the card image
const PHONE_FIT_LIMIT  = 9    // at or above this, the options scroll as well

function phoneFitCheck(card) {
  if (card.type !== "select_one_grid" && card.type !== "select_many_grid") return null
  let n = cleanOptions(card).length
  if (!n) return null
  if (card.allowOther) n += 1

  if (n >= PHONE_FIT_LIMIT) return check("phone", INFO, t("editor.rules.phone_scroll", { n }))
  if (n >= PHONE_HERO_LIMIT) return check("phone", INFO, t("editor.rules.phone_hero", { n }))
  return null
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

// A scenario's narrative pages — separate from the answer-option count check
// above, since a scenario has both (the story pages AND the final choice).
function pageCountCheck(card) {
  const n = cleanPages(card).length
  const { min, max } = PAGE_RULES
  if (n < min) return check("pages", RED, t("editor.rules.page_empty"))
  if (n > max) return check("pages", n <= max + 2 ? YELLOW : RED, t("editor.rules.page_many", { n, max }))
  return check("pages", GREEN, t("editor.rules.page_ok", { n, min, max }))
}

function pageLengthCheck(card) {
  const pages = cleanPages(card)
  if (!pages.length) return null
  const over = pages.filter((p) => p.length > PAGE_LENGTH_LIMIT)
  if (!over.length) return check("page_length", GREEN, t("editor.rules.page_length_ok", { max: PAGE_LENGTH_LIMIT }))
  const worst = over.reduce((a, b) => (b.length > a.length ? b : a))
  const rating = worst.length > PAGE_LENGTH_LIMIT * 1.5 ? RED : YELLOW
  return check("page_length", rating, t("editor.rules.page_length_long", { n: worst.length, max: PAGE_LENGTH_LIMIT }))
}

// ── Whole-Verto analysis ─────────────────────────────────────────────────
// `cards` is an ordered array of the same card objects — optionally carrying
// their wiring (cid / logic / next / flow_id) — and `flows` is the deck's
// first-class flow list. Returns
// { score, rating, checks, tally, cardCount, questionCount, pathLength }.
export function analyzeVerto(cards, { flows = [] } = {}) {
  const list = Array.isArray(cards) ? cards : []
  const checks = []

  // §1.1 — card count. The scored unit is CARDS (welcome included), per the
  // Rules of the Game table "12–16 inc. welcome/end" — but a BRANCHED Verto
  // is scored on the longest path one respondent can actually take, not the
  // flat deck: a 30-card deck split into three regional flows plays as ~14
  // cards, and punishing that with "trim to 16" would fight the feature. For
  // a linear deck the path length IS the deck length, so nothing changes.
  const cardCount = list.length
  const pathLength = longestPathLength(list)
  checks.push(cardCountCheck(pathLength))
  if (pathLength < cardCount) {
    checks.push(check("flows_path", INFO, t("editor.rules.flows_path", { n: pathLength, total: cardCount })))
  }

  // §1.2 — the weighted question count (a Tap card counts as its statements)
  // no longer drives the score, but still informs the pace tip below.
  const questionCount = list.reduce((sum, c) => {
    if (!isQuestion(c)) return sum
    return sum + (c.type === "tap_card" ? Math.max(cleanOptions(c).length, 1) : 1)
  }, 0)

  // §1.4 — answer diversity: never more than 2 of a type in a row. Judged per
  // GROUP a respondent actually sees in sequence — the main spine and each
  // flow separately — so a type run that only exists across a flow boundary
  // (never played back-to-back) isn't punished.
  checks.push(varietyCheck(list, flows))

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

  return { score, rating: rate(score), checks, tally, cardCount, questionCount, pathLength }
}

// ── Branch-aware deck length ─────────────────────────────────────────────
// Longest path (in cards) a respondent can take over the static routing
// graph, cycles broken — the JS mirror of LogicGraph.longest_path /
// edges_from (app/lib/logic_graph.rb); keep the edge rules in lock-step.
// A linear deck (no logic/next wiring) degenerates to the deck length, and
// cards no route reaches (a parked/orphaned branch) aren't counted — a
// respondent never sees them.

function edgesFrom(cards, i, ci) {
  const card = cards[i] || {}
  const outs = []
  let covered = false // a default / next (card or end) replaces the linear edge
  const logic = ROUTABLE_TYPES.includes(card.type) && card.logic && typeof card.logic === "object" ? card.logic : null
  if (logic) {
    ;(Array.isArray(logic.routes) ? logic.routes : []).forEach(r => {
      const to = r && r.to
      if (to && to.card && ci.has(to.card)) outs.push(ci.get(to.card))
    })
    const d = logic.default
    if (d && (d.card || d.end)) {
      covered = true
      if (d.card && ci.has(d.card)) outs.push(ci.get(d.card))
    }
  }
  const nx = card.next
  if (!covered && nx && (nx.card || nx.end)) {
    covered = true
    if (nx.card && ci.has(nx.card)) outs.push(ci.get(nx.card))
  }
  if (!covered && i + 1 < cards.length) outs.push(i + 1)
  return [ ...new Set(outs) ]
}

function longestPathLength(cards) {
  if (!cards.length) return 0
  const ci = new Map()
  cards.forEach((c, i) => { if (c && c.cid) ci.set(c.cid, i) })
  const memo = new Map()
  const visiting = new Set()
  const dfs = (i) => {
    if (i == null || i < 0 || i >= cards.length) return 0
    if (memo.has(i)) return memo.get(i)
    if (visiting.has(i)) return 0 // break cycle
    visiting.add(i)
    const best = Math.max(0, ...edgesFrom(cards, i, ci).map(dfs))
    visiting.delete(i)
    memo.set(i, 1 + best)
    return 1 + best
  }
  return dfs(0)
}

// §1.1 — green 12–16 cards, yellow 8–11, red under 8 or over 16.
function cardCountCheck(n) {
  if (n >= CARD_MIN && n <= CARD_MAX) return check("c_count", GREEN, t("editor.rules.ccount_ok", { n, min: CARD_MIN, max: CARD_MAX }))
  if (n > CARD_MAX) return check("c_count", RED, t("editor.rules.ccount_many", { n, max: CARD_MAX }))
  if (n >= CARD_YELLOW_MIN) return check("c_count", YELLOW, t("editor.rules.ccount_few", { n, min: CARD_MIN, max: CARD_MAX }))
  return check("c_count", RED, t("editor.rules.ccount_min", { n, min: CARD_MIN }))
}

function varietyCheck(cards, flows = []) {
  // One sequence per thing a respondent plays straight through: the main
  // spine (cards in no flow), then each flow's members. Without flows this
  // is just the flat deck, exactly as before.
  const flowIds = (Array.isArray(flows) ? flows : []).map((f) => f && f.id).filter(Boolean)
  const groups = flowIds.length
    ? [ cards.filter((c) => !c || !flowIds.includes(c.flow_id)),
        ...flowIds.map((id) => cards.filter((c) => c && c.flow_id === id)) ]
    : [ cards ]

  let worst = null
  groups.forEach((group) => {
    const types = group.filter(isQuestion).map((c) => c.type)
    let runType = null, runLen = 0
    types.forEach((ty) => {
      runLen = ty === runType ? runLen + 1 : 1
      runType = ty
      if (runLen > RUN_MAX && (!worst || runLen > worst.len)) worst = { type: ty, len: runLen }
    })
  })
  return worst
    ? check("variety", RED, t("editor.rules.variety_run", { type: typeLabel(worst.type), n: worst.len }))
    : check("variety", GREEN, t("editor.rules.variety_ok"))
}
