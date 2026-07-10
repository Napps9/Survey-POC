require "test_helper"

# A single "add a question" should strengthen Awareness/Intention/Agency
# coverage rather than pile on more of the same. coverage_summary tallies the
# tags already on the deck and nudges the model toward the gap.
class SingleQuestionCoverageTest < ActiveSupport::TestCase
  def summary(cards)
    SingleQuestionGenerator.allocate.send(:coverage_summary, cards)
  end

  test "an agency deck with no condition is nudged toward a wellbeing/belonging question" do
    s = summary([ { "competency" => "agency" }, { "competency" => "awareness" } ])
    assert_includes s, "agency×1"
    assert_includes s, "conditions: none"
    assert_includes s, "enabling-condition question"
    assert_includes s, "no intention question yet"
  end

  test "an all-awareness deck is nudged toward intention and agency" do
    s = summary([ { "competency" => "awareness" }, { "competency" => "awareness" } ])
    assert_includes s, "awareness×2"
    assert_includes s, "no intention or agency question yet"
  end

  test "a deck spanning the sequence with a condition just deepens coverage" do
    s = summary([
      { "competency" => "awareness" },
      { "competency" => "intention" },
      { "competency" => "agency", "condition" => "belonging" }
    ])
    assert_includes s, "conditions: belonging"
    assert_includes s, "deepen coverage"
    refute_includes s, "activation gap", "nothing is missing, so no gap nudge"
  end

  test "an untagged / older deck degrades gracefully" do
    s = summary([ { "type" => "range" }, { "type" => "nps" } ])
    assert_includes s, "awareness×0"
    assert_includes s, "no awareness or intention or agency question yet"
  end
end
