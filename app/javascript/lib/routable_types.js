// Which card types can carry per-answer routing, and how each type's answer
// is matched — the JS mirror of LogicGraph::ROUTABLE and its match ops (keep
// the three in lock-step: this file, logic_graph.rb, and player_controller's
// _logicMatch). Open text and swipe decks have no discrete answer to route
// on; they continue in card order (or via their unconditional `next`).
export const ROUTABLE_TYPES = [
  "multiple_choice", "yes_no", "scenario", "select_one_grid",
  "range", "rating", "nps",
  "select_many", "select_many_grid", "prioritise"
]

// One op per answer shape: scalars match by equality, multi-pick arrays fire
// when the answer INCLUDES the value (first matching route wins), prioritise
// fires on the TOP-RANKED value.
const MATCH_OPS = {
  select_many: "contains",
  select_many_grid: "contains",
  prioritise: "first"
}
export function matchOpFor(type) { return MATCH_OPS[type] || "equals" }

// The canonical routing value for one option — keyed like card.correct /
// card.tokens: the primary-language label for choice types, the numeric
// position for scales (range 0-4 step, rating 1-N stars; nps labels already
// ARE "0".."10").
export function canonicalFor(type, label, index) {
  if (type === "range") return String(index)
  if (type === "rating") return String(index + 1)
  return String(label)
}

// The full routable answer list for a card, as [{ label, canonical }]. Mostly
// its options — except rating, whose answer is ALWAYS 1..5 stars while its
// stored options are just the end captions.
export function routeOptionsFor(type, options) {
  const opts = Array.isArray(options) ? options : []
  if (type === "rating") {
    return Array.from({ length: 5 }, (_, i) =>
      ({ label: `${i + 1}★${opts[i] ? ` ${opts[i]}` : ""}`, canonical: String(i + 1) }))
  }
  return opts.map((o, i) => ({ label: String(o), canonical: canonicalFor(type, o, i) }))
}

// Types whose option LISTS are edited live in the card (so branching rows
// must rebuild as options change). The scales are absent on purpose: their
// canonicals are positional and their editors don't expose the option list.
export const OPTION_EDITED_TYPES = [
  "multiple_choice", "scenario", "select_one_grid",
  "select_many", "select_many_grid", "prioritise"
]
