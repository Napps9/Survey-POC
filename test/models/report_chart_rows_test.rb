require "test_helper"

# The report's figures. The per-type shapes mirror ResultsExport's summary CSV,
# so these mostly guard against the two drifting apart.
class ReportChartRowsTest < ActiveSupport::TestCase
  def result(type, counts, card: {}, total: 10)
    { type: type, card: card, counts: counts, total: total, other_texts: [] }
  end

  test "choice counts are ordered biggest first with shares of the whole" do
    rows = ReportChartRows.rows_for(result("multiple_choice", { "A" => 1, "B" => 7, "C" => 2 }))

    assert_equal %w[B C A], rows.map(&:label)
    assert_equal [ 70, 20, 10 ], rows.map(&:pct)
  end

  test "a range keeps scale order, not size order" do
    # Sorting a scale by popularity would scramble the thing it measures.
    card = { "options" => [ "Never", "Rarely", "Sometimes", "Often", "Always" ] }
    rows = ReportChartRows.rows_for(result("range", { 0 => 1, 1 => 9, 2 => 3, 3 => 2, 4 => 5 }, card: card))

    assert_equal [ "Never", "Rarely", "Sometimes", "Often", "Always" ], rows.map(&:label)
    assert_equal [ 1, 9, 3, 2, 5 ], rows.map(&:count)
  end

  test "an nps card keeps score order" do
    rows = ReportChartRows.rows_for(result("nps", { 10 => 4, 0 => 1, 7 => 2 }))
    assert_equal %w[0 7 10], rows.map(&:label)
  end

  test "a rating card lists all five stars even when unused" do
    rows = ReportChartRows.rows_for(result("rating", { 5 => 3, 3 => 1 }))

    assert_equal 5, rows.size
    assert_equal [ "1 star", "2 stars", "3 stars", "4 stars", "5 stars" ], rows.map(&:label)
    assert_equal [ 0, 0, 1, 0, 3 ], rows.map(&:count)
  end

  test "tap_card shares are per statement, not of the whole card" do
    # The bug this guards: dividing by the card's grand total would report
    # "9% said yes" for a statement where 43% of its answers were yes.
    counts = {
      "Renting is wasted" => { "yes" => 15, "unsure" => 0, "no" => 20 },
      "Cards are fine"    => { "yes" => 14, "unsure" => 1, "no" => 20 }
    }
    rows = ReportChartRows.rows_for(result("tap_card", counts))

    # Rows run in SCALE order (most negative first), for the reason raw_rows
    # gives for range and NPS: a scale drawn in any other order scrambles the
    # thing it measures. No 57%, Unsure 0%, Yes 43%.
    first = rows.first(3)
    assert_equal [ "Renting is wasted — No", "Renting is wasted — Unsure", "Renting is wasted — Yes" ],
                 first.map(&:label)
    assert_equal [ 57, 0, 43 ], first.map(&:pct)
    assert_equal 100, first.sum(&:pct), "a statement's shares should account for its own answers"
  end

  test "tap_card truncates whole statements, never half of one" do
    counts = 6.times.to_h { |i| [ "Statement #{i}", { "yes" => 3, "unsure" => 0, "no" => 1 } ] }
    rows   = ReportChartRows.rows_for(result("tap_card", counts))

    assert_equal 0, rows.size % 3, "a statement must not be cut mid-way"
    assert ReportChartRows.truncated?(result("tap_card", counts)),
           "dropping statements has to be disclosed, and the cap lives inside raw_rows"
  end

  test "prioritise is never charted" do
    # Its counts are a SUM OF RANKS, not a tally — bars would read as "how many
    # chose this" and be exactly backwards, since lower means higher priority.
    assert_empty ReportChartRows.rows_for(result("prioritise", { "A" => 12, "B" => 4 }))
    assert_not ReportChartRows.chartable?(result("prioritise", { "A" => 12, "B" => 4 }))
  end

  test "open_ended and empty cards are not charted" do
    assert_not ReportChartRows.chartable?(result("open_ended", {}))
    assert_not ReportChartRows.chartable?(result("multiple_choice", {}))
  end

  test "a single-category result is a figure, not a one-bar chart" do
    assert_not ReportChartRows.chartable?(result("multiple_choice", { "Only" => 9 }))
  end

  test "a card with no answers at all is skipped rather than dividing by zero" do
    assert_empty ReportChartRows.rows_for(result("multiple_choice", { "A" => 0, "B" => 0 }))
  end

  test "summary stats count responders, completions and questions" do
    org    = Organisation.create!(name: "O", slug: "rcr-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ]
    )
    survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", answers: { "1" => { "value" => "Yes" } })
    survey.responses.create!(session_token: SecureRandom.uuid, status: "started",   answers: { "1" => { "value" => "No" } })
    survey.responses.create!(session_token: SecureRandom.uuid, status: "started",   answers: {})

    stats = ReportChartRows.summary_stats(survey)
    assert_equal 2, stats[:responders], "an unanswered session isn't a responder"
    assert_equal 1, stats[:completed]
    assert_equal 50, stats[:completion]
    assert_equal 1, stats[:questions], "the welcome card isn't a question"
  end
end
