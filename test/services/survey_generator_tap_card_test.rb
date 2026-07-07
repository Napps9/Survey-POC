require "test_helper"

class SurveyGeneratorTapCardTest < ActiveSupport::TestCase
  test "enforce_tap_card_statement_bounds! trims tap_card options to 8" do
    gen = SurveyGenerator.allocate  # skip the API-key init; we only call the helper
    payload = {
      "cards" => [
        { "type" => "tap_card", "text" => "Q1", "options" => %w[a b c d e f g h i j] },
        { "type" => "multiple_choice", "text" => "Q2", "options" => %w[x y z w v u q r s t] },
        { "type" => "tap_card", "text" => "Q3", "options" => %w[only-one] },
        { "type" => "tap_card", "text" => "Q4", "options" => %w[n1 n2 neut p1 p2] },
        { "type" => "tap_card", "text" => "Q5", "options" => %w[a b c d e f g h] }
      ]
    }

    gen.send(:enforce_tap_card_statement_bounds!, payload)

    assert_equal 8, payload["cards"][0]["options"].size, "tap_card with 10 options trimmed to 8"
    assert_equal %w[a b c d e f g h], payload["cards"][0]["options"], "trimming keeps the first 8 (neg → neutral → pos order)"
    assert_equal 10, payload["cards"][1]["options"].size, "non-tap_card untouched"
    assert_equal 1, payload["cards"][2]["options"].size, "tap_card with fewer than 5 not padded (editor can extend)"
    assert_equal 5, payload["cards"][3]["options"].size, "tap_card already in the 5-8 band untouched"
    assert_equal 8, payload["cards"][4]["options"].size, "tap_card at exactly 8 untouched"
  end

  test "statement bound constants match the Rules of the Game" do
    assert_equal 5, SurveyGenerator::TAP_CARD_MIN_STATEMENTS
    assert_equal 8, SurveyGenerator::TAP_CARD_MAX_STATEMENTS
  end
end
