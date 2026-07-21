require "test_helper"

# The quiz score is computed entirely server-side from stored answers, so this
# locks the grading rules for every answer type.
class QuizGradingTest < ActiveSupport::TestCase
  def card(type, correct, extra = {})
    { "type" => type, "text" => "Q", "correct" => correct }.merge(extra)
  end

  test "a question is only graded when it carries a usable correct key" do
    refute QuizGrading.graded?({ "type" => "multiple_choice", "options" => %w[A B] })
    refute QuizGrading.graded?({ "type" => "welcome_card", "correct" => "A" })
    refute QuizGrading.graded?(card("multiple_choice", ""))
    refute QuizGrading.graded?(card("select_many", []))
    assert QuizGrading.graded?(card("multiple_choice", "A"))
    assert QuizGrading.graded?(card("open_ended", [ "Paris" ]))
    assert QuizGrading.graded?(card("tap_card", { "Earth is flat" => "no" }))
  end

  test "single-choice / yes-no / image-grid / scenario grade by exact canonical match" do
    %w[multiple_choice yes_no select_one_grid scenario].each do |type|
      c = card(type, "Blue")
      assert QuizGrading.correct?(c, "Blue")
      assert QuizGrading.correct?(c, " Blue "), "should ignore surrounding whitespace"
      refute QuizGrading.correct?(c, "Red")
      refute QuizGrading.correct?(c, nil)
    end
  end

  test "multi-select grades as an unordered set (all and only the correct labels)" do
    c = card("select_many", %w[Red Blue])
    assert QuizGrading.correct?(c, %w[Blue Red])
    refute QuizGrading.correct?(c, %w[Red]),            "missing one is wrong"
    refute QuizGrading.correct?(c, %w[Red Blue Green]), "an extra pick is wrong"
    refute QuizGrading.correct?(c, [])
  end

  test "tap_card grades every statement's swipe direction" do
    c = card("tap_card", { "Sky is blue" => "yes", "Earth is flat" => "no" })
    assert QuizGrading.correct?(c, { "Sky is blue" => "yes", "Earth is flat" => "no" })
    refute QuizGrading.correct?(c, { "Sky is blue" => "yes", "Earth is flat" => "yes" })
    refute QuizGrading.correct?(c, { "Sky is blue" => "yes" })
  end

  test "scales grade by value with an optional tolerance" do
    assert QuizGrading.correct?(card("rating", 5), 5)
    refute QuizGrading.correct?(card("rating", 5), 4)
    assert QuizGrading.correct?(card("nps", 3), 3)
    assert QuizGrading.correct?(card("range", 2, "correct_tolerance" => 1), 3)
    refute QuizGrading.correct?(card("range", 2, "correct_tolerance" => 1), 4)
    refute QuizGrading.correct?(card("range", 2), nil)
  end

  test "open_ended grades case- and space-insensitively against accepted answers" do
    c = card("open_ended", [ "Paris", "City of Paris" ])
    assert QuizGrading.correct?(c, "paris")
    assert QuizGrading.correct?(c, "  PARIS ")
    assert QuizGrading.correct?(c, "city of   paris")
    refute QuizGrading.correct?(c, "London")
    refute QuizGrading.correct?(c, "")
  end

  test "score tallies graded cards only and reports per-card correctness" do
    cards = [
      { "type" => "welcome_card" },
      card("multiple_choice", "Blue"),
      { "type" => "open_ended", "text" => "feelings" }, # ungraded measurement Q
      card("open_ended", [ "Paris" ])
    ]
    answers = {
      "1" => { "type" => "multiple_choice", "value" => "Blue" },
      "2" => { "type" => "open_ended", "value" => "anything" },
      "3" => { "type" => "open_ended", "value" => "London" }
    }
    result = QuizGrading.score(cards, answers)
    assert_equal 2, result[:max], "only the two graded cards count toward max"
    assert_equal 1, result[:score]
    assert_equal({ 1 => true, 3 => false }, result[:per_card])
  end
end
