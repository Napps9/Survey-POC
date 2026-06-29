require "test_helper"

class AggregatesSurveyResultsTest < ActiveSupport::TestCase
  # Tiny includer to exercise the private concern method directly.
  class Aggregator
    include AggregatesSurveyResults
    def run(cards, responses) = aggregate_results(cards, responses)
  end

  def setup
    @agg = Aggregator.new
  end

  # Build plain in-memory Response objects so the array path is exercised
  # (no DB needed); each answers hash is keyed by card index as a string.
  def resp(answers) = Response.new(answers: answers)

  CARDS = [
    { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B] }, # 0
    { "type" => "select_many",     "text" => "Many", "options" => %w[X Y] }, # 1
    { "type" => "rating",          "text" => "Rate", "options" => %w[Lo Hi] }, # 2
    { "type" => "range",           "text" => "Range" }, # 3
    { "type" => "tap_card",        "text" => "Tap" }, # 4
    { "type" => "open_ended",      "text" => "Say" }, # 5
    { "type" => "welcome_card",    "title" => "Hi" } # 6 (else branch)
  ].freeze

  def sample_responses
    [
      resp({
        "0" => { "value" => "A" },
        "1" => { "value" => %w[X Y] },
        "2" => { "value" => 4 },
        "3" => { "value" => 2 },
        "4" => { "value" => { "Statement 1" => "yes" } },
        "5" => { "value" => "Loved it" }
      }),
      resp({
        "0" => { "value" => nil, "other" => "Custom" }, # Other
        "1" => { "value" => %w[X] },
        "2" => { "value" => 2 },
        "3" => { "value" => 5 },
        "4" => { "value" => { "Statement 1" => "no" } },
        "5" => { "value" => "" } # blank text — counts toward total, not texts
      }),
      resp({ "0" => { "value" => "B" } })
    ]
  end

  test "multiple_choice tallies counts, Other, and total" do
    row = @agg.run(CARDS, sample_responses)[0]
    assert_equal 3, row[:total] # A + B + Other
    assert_equal 1, row[:counts]["A"]
    assert_equal 1, row[:counts]["B"]
    assert_equal 1, row[:counts]["Other"]
    assert_equal [ "Custom" ], row[:other_texts]
  end

  test "select_many counts each selection but totals responders" do
    row = @agg.run(CARDS, sample_responses)[1]
    assert_equal 2, row[:total]      # two responders answered
    assert_equal 2, row[:counts]["X"]
    assert_equal 1, row[:counts]["Y"]
  end

  test "rating averages over responders" do
    row = @agg.run(CARDS, sample_responses)[2]
    assert_equal 2, row[:total]
    assert_equal 3.0, row[:avg] # (4 + 2) / 2
    assert_equal 1, row[:counts][4]
    assert_equal 1, row[:counts][2]
  end

  test "range buckets by integer" do
    row = @agg.run(CARDS, sample_responses)[3]
    assert_equal({ 2 => 1, 5 => 1 }, row[:counts].to_h)
    assert_equal 2, row[:total]
  end

  test "tap_card tallies yes/no per statement" do
    row = @agg.run(CARDS, sample_responses)[4]
    assert_equal({ "yes" => 1, "no" => 1 }, row[:counts]["Statement 1"])
    assert_equal 2, row[:total]
  end

  test "open_ended keeps non-blank texts but totals all answers" do
    row = @agg.run(CARDS, sample_responses)[5]
    assert_equal [ "Loved it" ], row[:texts]
    assert_equal 2, row[:total] # both answered (one blank), blank excluded from texts
  end

  test "non-question card totals all responses" do
    row = @agg.run(CARDS, sample_responses)[6]
    assert_equal 3, row[:total]
    assert_equal({}, row[:counts])
  end

  test "handles an empty response set" do
    rows = @agg.run(CARDS, [])
    assert_equal 0, rows[0][:total]
    assert_equal 0.0, rows[2][:avg]
  end
end
