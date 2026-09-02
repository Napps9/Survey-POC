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
        { "type" => "scenario", "text" => "Which path?", "pages" => [ { "id" => "pg1", "text" => "You reach a fork in the trail." } ], "options" => %w[Left Right] },
        { "type" => "open_ended", "text" => "Comments?" }
      ]
    )
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en", answers: {
      "1" => { "type" => "multiple_choice", "value" => "Blue" },
      "2" => { "type" => "select_many", "value" => %w[Apple Cherry] },
      "3" => { "type" => "range", "value" => 3 },
      "4" => { "type" => "rating", "value" => 5 },
      "5" => { "type" => "tap_card", "value" => { "Stmt A" => "yes", "Stmt B" => "no" } },
      "6" => { "type" => "scenario", "value" => "Left" },
      "7" => { "type" => "open_ended", "value" => "Great job" }
    })
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "es", answers: {
      "1" => { "type" => "multiple_choice", "value" => nil, "other" => "Purple" },
      "2" => { "type" => "select_many", "value" => %w[Banana] },
      "3" => { "type" => "range", "value" => 0 },
      "4" => { "type" => "rating", "value" => 3 },
      "5" => { "type" => "tap_card", "value" => { "Stmt A" => "no", "Stmt B" => "no" } },
      "6" => { "type" => "scenario", "value" => "Right" },
      "7" => { "type" => "open_ended", "value" => "" }
    })
    responses   = @survey.responses.where(status: "completed").order(:created_at)
    aggregated  = AGG.build(Array(@survey.cards), responses)
    @export     = ResultsExport.new(survey: @survey, responses: responses, aggregated: aggregated)
  end

  def teardown
    @survey.destroy
    @org.destroy
  end

  # Answer columns start after the per-response metadata columns. Derived from
  # the constant rather than hard-coded, so adding a metadata column doesn't
  # send every index below off by one.
  META = ResultsExport::RESPONSE_HEADER.size

  test "response_rows header lists question texts and skips the welcome card" do
    header = @export.response_rows.first
    assert_equal [ "Response ID", "Submitted at", "Source", "Language",
                   "Duration (seconds)", "Device", "Responder", "Device group" ], header.first(META).map(&:to_s)
    assert_equal [ "Favourite colour?", "Which fruits?", "How happy?", "Rate us", "Agree?", "Which path?", "Comments?" ], header[META..]
    refute_includes header, "Welcome"
  end

  SOURCE_COL = ResultsExport::RESPONSE_HEADER.index("Source")

  # Which address a response came in on. A custom link names itself; recalling
  # the link keeps the name on its old rows; deleting it (nullify) drops them
  # back to the Verto's own address.
  test "the Source column names the custom link a response came through" do
    link = @survey.survey_links.create!(name: "Newsletter", slug: "rex-news-#{SecureRandom.hex(2)}")
    via_link = @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en",
                                         survey_link: link,
                                         answers: { "1" => { "type" => "multiple_choice", "value" => "Red" } })
    rebuild_export!

    rows = @export.response_rows.drop(1)
    assert_equal [ "Direct link", "Direct link", "Newsletter" ], rows.map { |r| r[SOURCE_COL] },
                 "the plain rows keep the Verto's own label; the link row carries its name"

    link.update!(active: false)
    rebuild_export!
    assert_equal "Newsletter", @export.response_rows.last[SOURCE_COL], "a recalled link still labels its old responses"

    link.destroy
    rebuild_export!
    assert_equal "Direct link", @export.response_rows.last[SOURCE_COL],
                 "a deleted link nullifies its stamp, so the row reads as the Verto's own again"
    assert_nil via_link.reload.survey_link_id
  end

  def rebuild_export!
    responses  = @survey.responses.where(status: "completed").order(:created_at)
    aggregated = AGG.build(Array(@survey.cards), responses)
    @export    = ResultsExport.new(survey: @survey, responses: responses, aggregated: aggregated)
  end

  test "response_rows formats each card type and the Other free-text" do
    rows = @export.response_rows
    assert_equal 3, rows.size # header + 2 responses

    first = rows[1]
    assert_equal "Blue", first[META]
    assert_equal "Apple; Cherry", first[META + 1]           # select_many joined
    assert_equal "Good", first[META + 2]                    # range index 3 -> options[3]
    assert_equal "5", first[META + 3]                        # rating
    # The response LABEL, not the key it is stored under: "strongly_agree" is
    # not a thing anyone said, and on a renamed scale it isn't even close.
    assert_equal "Stmt A: Yes; Stmt B: No", first[META + 4] # tap_card hash
    assert_equal "Left", first[META + 5]                     # scenario, formatted like multiple_choice
    assert_equal "Great job", first[META + 6]

    second = rows[2]
    assert_equal "Other: Purple", second[META]              # value nil + other
    assert_equal "Banana", second[META + 1]
    assert_equal "Sad", second[META + 2]                    # range index 0
    assert_equal "Right", second[META + 5]
    assert_equal "", second[META + 6]                        # blank open_ended
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

    path = rows.select { |r| r[2] == "Which path?" }
    assert_includes path, [ 7, "scenario", "Which path?", "Left", 1, 50.0, 2 ]
    assert_includes path, [ 7, "scenario", "Which path?", "Right", 1, 50.0, 2 ]

    refute rows.any? { |r| r[1] == "welcome_card" }, "welcome card should be excluded from the summary"
  end

  # ── Responder / Device group columns ───────────────────────────────────────
  # A responder = rows sharing respondent_code_digest; the export groups their
  # runs under one minted anonymous name. The digests themselves must never
  # appear — a digest is a stable cross-export handle on a hashed value.

  RESP_COL = ResultsExport::RESPONDER_COLUMN
  DEV_COL  = ResultsExport::DEVICE_GROUP_COLUMN

  def coded_response(code:, at:, device: nil)
    @survey.responses.create!(
      session_token: SecureRandom.uuid, status: "completed", locale: "en",
      answers: { "1" => { "type" => "multiple_choice", "value" => "Blue" } },
      respondent_code_digest: code && @survey.respondent_code_digest(code),
      player_key_digest: device && @survey.player_key_digest(device),
      created_at: at, updated_at: at)
  end

  def fresh_export(responses = @survey.responses.where(status: "completed").order(:created_at))
    ResultsExport.new(survey: @survey, responses: responses,
                      aggregated: AGG.build(Array(@survey.cards), responses))
  end

  test "rows group by responder under one minted name, uncoded rows last" do
    a1 = coded_response(code: "sam14", at: 4.days.ago)
    b  = coded_response(code: "blue7", at: 3.days.ago)
    a2 = coded_response(code: "SAM 14", at: 2.days.ago) # normalizes to sam14

    body = fresh_export.response_rows.drop(1)
    named, blank = body.partition { |r| r[RESP_COL].present? }

    # The two uncoded setup responses trail every named group — even though
    # they were created after the coded ones.
    assert_equal 2, blank.size
    assert_equal blank, body.last(2), "uncoded rows must sort behind every named group"

    sam_rows = named.select { |r| [ a1.id, a2.id ].include?(r[0]) }
    assert_equal 1, sam_rows.map { |r| r[RESP_COL] }.uniq.size,
                 "the same normalized code must always wear the same name"
    assert_equal [ a1.id, a2.id ], sam_rows.map { |r| r[0] }, "runs in play order"
    assert_equal sam_rows[1], body[body.index(sam_rows[0]) + 1],
                 "a responder's runs must sit on adjacent rows"

    blue_name = named.find { |r| r[0] == b.id }[RESP_COL]
    refute_equal sam_rows.first[RESP_COL], blue_name
    assert RespondentAlias.exists?(survey_id: @survey.id, anon_name: blue_name),
           "the label is a minted alias, not derived text"
  end

  test "the export never contains a digest or a typed code" do
    row = coded_response(code: "sam14", at: 1.day.ago, device: "device-uuid-1")

    flat = fresh_export.response_rows.flatten.map(&:to_s).join("|")
    refute_includes flat, row.respondent_code_digest
    refute_includes flat, row.player_key_digest
    refute_includes flat, "sam14"
  end

  test "Device group wears the leaderboard's exact name, stable across exports" do
    row = coded_response(code: nil, at: 1.day.ago, device: "device-uuid-9")
    board_name = PlayerAlias.ensure_for!(survey: @survey, key_digest: row.player_key_digest).anon_name

    first  = fresh_export.response_rows.drop(1).find { |r| r[0] == row.id }
    assert_equal board_name, first[DEV_COL], "one browser, one name — board and export agree"
    assert_equal "", first[RESP_COL], "no code entered means no responder"

    again = fresh_export.response_rows.drop(1).find { |r| r[0] == row.id }
    assert_equal board_name, again[DEV_COL], "minted names never change between exports"
  end

  test "the relation and in-memory branches produce identical rows" do
    coded_response(code: "sam14", at: 3.days.ago)
    coded_response(code: "blue7", at: 2.days.ago)
    coded_response(code: "sam14", at: 1.day.ago)

    relation = @survey.responses.where(status: "completed").order(:created_at)
    assert_equal fresh_export(relation).response_rows,
                 fresh_export(relation.to_a).response_rows
  end
end
