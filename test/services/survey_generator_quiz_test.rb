require "test_helper"

# Quiz generation: the model's `correct` is coerced into the stored shape and
# only kept when it genuinely matches the card's options, so a stray value
# leaves the question ungraded rather than permanently wrong.
class SurveyGeneratorQuizTest < ActiveSupport::TestCase
  def normalize(cards)
    gen = SurveyGenerator.allocate # skip the API-key init; only the helper is exercised
    gen.send(:normalize_quiz_correct!, { "cards" => cards })["cards"]
  end

  test "single-choice keeps a correct label that's an option, drops one that isn't" do
    cards = normalize([
      { "type" => "multiple_choice", "options" => %w[Paris London], "correct" => [ "Paris" ], "explanation" => "cap" },
      { "type" => "multiple_choice", "options" => %w[Paris London], "correct" => [ "Madrid" ], "explanation" => "x" }
    ])
    assert_equal "Paris", cards[0]["correct"]
    assert_equal "cap", cards[0]["explanation"]
    assert_nil cards[1]["correct"]
    assert_nil cards[1]["explanation"], "explanation is dropped with an unusable correct"
  end

  test "yes_no normalises to canonical Yes/No and select_many keeps valid options in order" do
    cards = normalize([
      { "type" => "yes_no", "correct" => [ "yes" ] },
      { "type" => "select_many", "options" => %w[Red Blue Green], "correct" => %w[Blue Red Bogus] }
    ])
    assert_equal "Yes", cards[0]["correct"]
    assert_equal %w[Red Blue], cards[1]["correct"]
  end

  test "open_ended keeps the accepted answers; scales and tap_card are left ungraded" do
    cards = normalize([
      { "type" => "open_ended", "correct" => [ "4", "four" ] },
      { "type" => "range", "options" => %w[Low Mid High], "correct" => [ "High" ], "explanation" => "y" },
      { "type" => "tap_card", "options" => %w[a b c], "correct" => [ "a" ] }
    ])
    assert_equal %w[4 four], cards[0]["correct"]
    assert_nil cards[1]["correct"], "the generator doesn't grade scales"
    assert_nil cards[2]["correct"], "the generator doesn't grade tap_card"
  end

  test "the emit_survey schema gains correct + explanation only in quiz mode" do
    gen  = SurveyGenerator.allocate
    tool = SurveyGenerator::TOOL.deep_dup
    props = tool[:input_schema][:properties][:cards][:items][:properties]
    refute props.key?(:correct)
    gen.send(:inject_quiz_schema!, tool)
    assert props.key?(:correct)
    assert props.key?(:explanation)
  end
end
