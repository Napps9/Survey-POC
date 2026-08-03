// Mirror of Survey::OPTION_STYLE_TYPES (app/models/survey.rb). The editor
// serializes per-option style overrides only for these types; the server
// sanitiser drops the key everywhere else. Keep in sync — the parity test
// asserts it.
export const OPTION_STYLE_TYPES = [
  "multiple_choice", "select_many", "prioritise", "yes_no",
  "select_one_grid", "select_many_grid", "scenario"
]
