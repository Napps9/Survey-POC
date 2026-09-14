// The card types whose ANSWER takes the whole phone screen — the JS mirror of
// CardTypes::FULL_SCREEN_ANSWER_TYPES (app/lib/card_types.rb).
//
// A tap matrix's stack cannot shrink, an NPS scale cannot either, and a
// prioritise list's rows are drag targets, so one below the fold cannot even be
// scrolled to. The phone therefore draws all three no hero strip at all.
//
// Which makes them exactly the cards that can carry a MOBILE BACKGROUND: on
// every other type the phone shows the card's own picture, so a backdrop behind
// it would be a control that does nothing; on these three there is no hero to
// be behind, and the backdrop is the only design a phone can carry. The editor
// decides whether to offer the control from this list, and the server decides
// whether to store what it sets from the Ruby one — so they have to agree, and
// test/lib/js_constant_parity_test.rb asserts they do.
export const FULL_SCREEN_ANSWER_TYPES = [ "tap_card", "nps", "prioritise" ]

export function isFullScreenAnswer(type) {
  return FULL_SCREEN_ANSWER_TYPES.includes(type || "")
}
