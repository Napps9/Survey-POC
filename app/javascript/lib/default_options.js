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

// Types whose details form shows an editable list of answer options.
export const OPTION_TYPES = new Set([
  "multiple_choice", "select_many", "prioritise",
  "select_one_grid", "select_many_grid",
  "tap_card", "scenario"
])

// Types whose details form shows min / max scale labels instead of a list.
export const LABEL_TYPES = new Set([ "range", "rating" ])
