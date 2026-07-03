require "test_helper"

class DemographicQuestionsTest < ActiveSupport::TestCase
  test "the birth-date card uses the month+year-only picker, not free text" do
    card = DemographicQuestions.cards.find { |c| c["text"] == "When were you born?" }
    assert_equal "month", card["input"]
    assert card["demographic"]
  end

  test "append_to adds the demographic tail once and never duplicates it" do
    cards = [ { "type" => "welcome_card", "text" => "Welcome" } ]
    once  = DemographicQuestions.append_to(cards)
    assert_equal 4, once.size

    twice = DemographicQuestions.append_to(once)
    assert_equal once, twice
  end
end
