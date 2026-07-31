// Bounds on a paged card's narrative pages — the JS mirror of
// Survey::MAX_SCENARIO_PAGES and Survey::MAX_SCENARIO_PAGE_LENGTH
// (app/models/survey.rb).
//
// These had no client-side counterpart at all, so the editor happily let a
// creator write a seventh page and the sanitiser dropped it on the next save
// with nothing said. The only nearby numbers were verto_rules' PAGE_RULES.max
// (5) and PAGE_LENGTH_LIMIT (400), which are advisory SCORING thresholds and
// deliberately stricter than these — a creator is nudged at 5 pages / 400
// characters long before anything is actually discarded at 6 / 600.
//
// test/lib/js_constant_parity_test.rb asserts these match the Ruby constants.
export const MAX_PAGES = 6
export const MAX_PAGE_LENGTH = 600
