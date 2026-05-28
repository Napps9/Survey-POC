require "test_helper"

class SurveyGeneratorTapCardTest < ActiveSupport::TestCase
  test "enforce_tap_card_three_statements! trims tap_card options to 3" do
    gen = SurveyGenerator.allocate  # skip the API-key init; we only call the helper
    payload = {
      "cards" => [
        { "type" => "tap_card", "text" => "Q1", "options" => %w[a b c d e] },
        { "type" => "multiple_choice", "text" => "Q2", "options" => %w[x y z w] },
        { "type" => "tap_card", "text" => "Q3", "options" => %w[only-one] },
        { "type" => "tap_card", "text" => "Q4", "options" => %w[neg neut pos] }
      ]
    }

    gen.send(:enforce_tap_card_three_statements!, payload)

    assert_equal 3, payload["cards"][0]["options"].size, "tap_card with 5 options trimmed to 3"
    assert_equal %w[a b c], payload["cards"][0]["options"], "trimming keeps the first 3 (neg/neutral/pos order)"
    assert_equal 4, payload["cards"][1]["options"].size, "non-tap_card untouched"
    assert_equal 1, payload["cards"][2]["options"].size, "tap_card with fewer than 3 not padded (editor can extend)"
    assert_equal 3, payload["cards"][3]["options"].size, "tap_card already at 3 untouched"
  end
end
