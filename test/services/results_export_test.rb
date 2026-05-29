require "test_helper"

class ResultsExportTest < ActiveSupport::TestCase
  # Computes aggregate_results the same way the controllers do.
  AGG = Class.new do
    include AggregatesSurveyResults
    def build(cards, responses) = aggregate_results(cards, responses)
  end.new

  def setup
    @org = Organisation.create!(name: "T", slug: "rex-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Welcome" },
        { "type" => "multiple_choice", "text" => "Favourite colour?", "options" => %w[Blue Green Red], "allow_other" => true },
        { "type" => "select_many", "text" => "Which fruits?", "options" => %w[Apple Banana Cherry] },
        { "type" => "range", "text" => "How happy?", "options" => %w[Sad Meh Neutral Good Great] },
        { "type" => "rating", "text" => "Rate us" },
        { "type" => "tap_card", "text" => "Agree?", "options" => [ "Stmt A", "Stmt B" ] },
        { "type" => "open_ended", "text" => "Comments?" }
      ]
    )
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answers: {
      "1" => { "type" => "multiple_choice", "value" => "Blue" },
      "2" => { "type" => "select_many", "value" => %w[Apple Cherry] },
      "3" => { "type" => "range", "value" => 3 },
      "4" => { "type" => "rating", "value" => 5 },
      "5" => { "type" => "tap_card", "value" => { "Stmt A" => "yes", "Stmt B" => "no" } },
      "6" => { "type" => "open_ended", "value" => "Great job" }
    })
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "es", answers: {
      "1" => { "type" => "multiple_choice", "value" => nil, "other" => "Purple" },
      "2" => { "type" => "select_many", "value" => %w[Banana] },
      "3" => { "type" => "range", "value" => 0 },
      "4" => { "type" => "rating", "value" => 3 },
      "5" => { "type" => "tap_card", "value" => { "Stmt A" => "no", "Stmt B" => "no" } },
      "6" => { "type" => "open_ended", "value" => "" }
    })
    responses   = @survey.responses.where(status: "completed").order(:created_at)
    aggregated  = AGG.build(Array(@survey.cards), responses)
    @export     = ResultsExport.new(survey: @survey, responses: responses, aggregated: aggregated)
  end

  def teardown
    @survey.destroy
    @org.destroy
  end

  test "response_rows header lists question texts and skips the welcome card" do
    header = @export.response_rows.first
    assert_equal %w[Response\ ID Submitted\ at Source Language], header.first(4).map(&:to_s)
    assert_equal [ "Favourite colour?", "Which fruits?", "How happy?", "Rate us", "Agree?", "Comments?" ], header[4..]
    refute_includes header, "Welcome"
  end

  test "response_rows formats each card type and the Other free-text" do
    rows = @export.response_rows
    assert_equal 3, rows.size # header + 2 responses

    first = rows[1]
    assert_equal "Blue", first[4]
    assert_equal "Apple; Cherry", first[5]           # select_many joined
    assert_equal "Good", first[6]                    # range index 3 -> options[3]
    assert_equal "5", first[7]                        # rating
    assert_equal "Stmt A: yes; Stmt B: no", first[8] # tap_card hash
    assert_equal "Great job", first[9]

    second = rows[2]
    assert_equal "Other: Purple", second[4]          # value nil + other
    assert_equal "Banana", second[5]
    assert_equal "Sad", second[6]                    # range index 0
    assert_equal "", second[9]                       # blank open_ended
  end

  test "summary_rows produce counts and percentages per option" do
    rows = @export.summary_rows
    assert_equal ResultsExport::SUMMARY_HEADER, rows.first

    colour = rows.select { |r| r[2] == "Favourite colour?" }
    assert_includes colour, [ 2, "multiple_choice", "Favourite colour?", "Blue", 1, 50.0, 2 ]
    assert_includes colour, [ 2, "multiple_choice", "Favourite colour?", "Other", 1, 50.0, 2 ]

    happy = rows.select { |r| r[2] == "How happy?" }
    assert_equal 5, happy.size # one row per range step
    assert_includes happy, [ 4, "range", "How happy?", "Good", 1, 50.0, 2 ]

    rating = rows.select { |r| r[2] == "Rate us" }
    assert_includes rating, [ 5, "rating", "Rate us", "Average (1–5)", 4.0, nil, 2 ]

    agree = rows.select { |r| r[2] == "Agree?" }
    assert_includes agree, [ 6, "tap_card", "Agree?", "Stmt B — No", 2, 100.0, 2 ]

    refute rows.any? { |r| r[1] == "welcome_card" }, "welcome card should be excluded from the summary"
  end
end
