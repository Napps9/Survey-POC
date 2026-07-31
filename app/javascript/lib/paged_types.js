// Card types whose content is a sequence of `pages` ({ id, text }) rather than
// options — the JS mirror of Survey::PAGED_TYPES (app/models/survey.rb).
//
// This list exists because it was previously a literal `type === "scenario"`
// in four places. When consent_gate joined PAGED_TYPES on the server, those
// four kept meaning "scenario only", and serialize() stopped emitting `pages`
// for a consent gate — so every autosave posted a consent card with no pages,
// the sanitiser rewrote them to [], and the gate went on blocking respondents
// while showing a blank screen and recording no consent snapshot.
//
// test/lib/js_constant_parity_test.rb asserts this file and survey.rb agree, so
// the next type to join cannot drift the same way.
export const PAGED_TYPES = [ "scenario", "consent_gate" ]

export function isPaged(type) { return PAGED_TYPES.includes(type) }
