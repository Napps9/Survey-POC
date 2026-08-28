// The "how to answer" caption above a question — the line a respondent reads
// as the instruction. It is DERIVED from the card, never authored: normally
// from its type ("Choose all that apply"), but on a multi-select carrying a
// tick ceiling it has to name the ceiling instead ("Choose up to 3").
//
// Three places render this string and they have to agree, because two of them
// write over the third's output on the same card:
//
//   1. shared/_card_component.html.erb — the server render (editor primary tab
//      and the player). It has the card hash and Rails' own interpolation, so
//      it carries its own copy of this rule.
//   2. type_panel_controller — after a type switch.
//   3. survey_editor_controller — after a translation-tab switch.
//
// This is the one 2 and 3 share. `eyebrows` is the per-locale blob emitted by
// application_helper.rb#card_eyebrows_i18n: { locale: { <type>: caption,
// _max: "Choose up to %{n}" } }.

// The types a ceiling means anything on — mirrors Survey::MULTI_SELECT_TYPES.
// A type switch can leave data-card-max-choices behind on a card that is no
// longer a multi-select, so the caption checks the type rather than trusting
// the attribute.
export const MULTI_SELECT_TYPES = [ "select_many", "select_many_grid" ]

export function cardEyebrow(eyebrows, locale, type, max, fallback = "") {
  const captions = (eyebrows && eyebrows[locale]) || {}
  const n = parseInt(max, 10)
  if (MULTI_SELECT_TYPES.includes(type) && n >= 2 && captions._max) {
    return captions._max.replace("%{n}", n)
  }
  return captions[type] || fallback
}
