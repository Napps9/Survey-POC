// Card types that capture no answer — the JS mirror of
// CardTypes::NON_QUESTION_TYPES (app/lib/card_types.rb).
//
// This list was written out by hand in FOUR places: type_panel_controller,
// survey_editor_controller, verto_rules and results_compare_controller. Three
// stayed in step; the fourth did not. results_compare_controller's copy was
// still the two-element version from before `consent_gate` existed, so the
// compare view built a card block for a consent gate, found no rows for it, and
// rendered an empty expandable section.
//
// Four copies of a list is four chances to miss one. There is one now, and
// test/lib/js_constant_parity_test.rb asserts it matches the Ruby.
export const NON_QUESTION_TYPES = [ "welcome_card", "token_checkpoint", "points_intro", "consent_gate", "respondent_code" ]

export function isQuestionType(type) {
  return !NON_QUESTION_TYPES.includes(type || "")
}
