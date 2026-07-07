require "test_helper"

# Guards the "Rules of the Game" values baked into the generator's prompt and
# schema so they can't silently drift from the source rules document (and from
# app/javascript/lib/verto_rules.js, which re-expresses the same values as
# live editor checks).
class SurveyGeneratorRulesTest < ActiveSupport::TestCase
  test "the emit_survey schema targets 12-15 cards including the welcome card" do
    cards = SurveyGenerator::TOOL[:input_schema][:properties][:cards]
    assert_equal 12, cards[:minItems]
    assert_equal 15, cards[:maxItems]
    assert_match "including the single opening welcome_card", cards[:description]
  end

  test "CARD_RULES carries the updated per-type bounds" do
    rules = SurveyGenerator::CARD_RULES
    assert_match "3 or 5",  rules, "image lists are an odd 3 or 5"
    assert_match "5 to 8",  rules, "tap cards carry 5-8 statements"
    assert_match "40 char", rules, "tap statements get a 40-char budget"
    assert_match "4 or 5 options (4 ideal)", rules, "prioritise is 4-5, 4 ideal"
    assert_match "EXACTLY 11 options", rules, "nps is the 0-10 (11-point) scale"
    assert_match(/"0" through\s+"10"/, rules, "nps labels are the plain numerals")
    assert_match "ONE label per point", rules, "rating supplies per-step labels, not just end captions"
  end

  test "the SYSTEM prompt scores cards, keeps variety per-type, and drops the scale family" do
    system = SurveyGenerator::SYSTEM
    assert_match "12 to 15 cards TOTAL", system
    assert_no_match(/scale.{0,3}famil/i, system, "range/rating/nps are individual types again")
    assert_match "individual answer types", system
  end
end
