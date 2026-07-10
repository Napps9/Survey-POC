require "test_helper"

# The generators tag each question with an Awareness/Intention/Agency
# competency, a plain-language `outcome`, and an optional enabling `condition`.
# The schema carries the fields, and normalize_framework! drops any
# competency/condition the model invents that isn't a known Framework key.
class SurveyGeneratorFrameworkTest < ActiveSupport::TestCase
  def normalize(cards)
    gen = SurveyGenerator.allocate # skip the API-key init; only the helper is exercised
    payload = { "cards" => cards }
    gen.send(:normalize_framework!, payload) # mutates in place
    payload["cards"]
  end

  test "emit_survey schema carries competency / outcome / condition" do
    props = SurveyGenerator::TOOL[:input_schema][:properties][:cards][:items][:properties]
    assert_equal Framework::COMPETENCY_KEYS, props[:competency][:enum]
    assert_equal Framework::CONDITION_KEYS, props[:condition][:enum]
    assert props.key?(:outcome)
  end

  test "the single-question and optimiser schemas carry the fields too" do
    sq = SingleQuestionGenerator::TOOL[:input_schema][:properties]
    assert_equal Framework::COMPETENCY_KEYS, sq[:competency][:enum]
    assert sq.key?(:outcome)

    co = CardOptimiser::TOOL[:input_schema][:properties]
    assert co.key?(:outcome), "the optimiser refreshes the outcome line"
  end

  test "SYSTEM prompt teaches Awareness/Intention/Agency from Framework" do
    assert_includes SurveyGenerator::SYSTEM, "Awareness, Intention & Agency"
    Framework::COMPETENCY_KEYS.each { |k| assert_includes SurveyGenerator::SYSTEM, k }
  end

  test "normalize_framework! keeps valid tags and drops invalid ones" do
    cards = normalize([
      { "type" => "range", "competency" => "agency", "condition" => "belonging", "outcome" => "Shows who acts" },
      { "type" => "range", "competency" => "bogus",  "condition" => "nope" },
      { "type" => "welcome_card" }
    ])

    assert_equal "agency", cards[0]["competency"]
    assert_equal "belonging", cards[0]["condition"]
    assert_equal "Shows who acts", cards[0]["outcome"], "free-text outcome is untouched"

    refute cards[1].key?("competency"), "an unknown competency is dropped"
    refute cards[1].key?("condition"), "an unknown condition is dropped"

    refute cards[2].key?("competency")
  end
end
