require "test_helper"

# Free text is held out of the database's answer column until moderation
# passes it — see app/lib/moderation.rb. These run the real write path
# (/progress, /submit, /consent) with the hold ON, as production has it.
class ModerationHoldTest < ActionDispatch::IntegrationTest
  AGG = Class.new do
    include AggregatesSurveyResults
    def build(cards, responses) = aggregate_results(cards, responses)
  end.new

  def setup
    @previous_hold = Moderation.hold_enabled
    Moderation.hold_enabled = true
    @org = Organisation.create!(name: "O", slug: "mh-#{SecureRandom.hex(3)}")
  end

  def teardown
    Moderation.hold_enabled = @previous_hold
  end

  def survey_with(cards, **extra)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards,
                         publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **extra)
  end

  def post_answers!(survey, answers, token: SecureRandom.uuid, path: :progress, extra: {})
    url = path == :submit ? submit_survey_path(survey.publish_token) : progress_survey_path(survey.publish_token)
    post url, params: { session_token: token, answers: answers }.merge(extra).to_json,
              headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success, response.body
    survey.responses.find_by!(session_token: token)
  end

  OPEN = [ { "type" => "open_ended", "text" => "Why?" } ].freeze

  # ── The hold ──────────────────────────────────────────────────────────────

  test "a typed answer is held: the row has the text, the answer has a marker, a screen is queued" do
    s = survey_with(OPEN)

    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Because it matters" } })

    assert_equal({ "type" => "open_ended", "value" => nil, "held" => { "value" => true } }, resp.answers["0"])
    assert resp.answered?, "a held answer is still an answer"
    held = resp.held_texts.sole
    assert_equal "Because it matters", held.text
    assert_equal "pending", held.status
    assert_equal "Why?", held.question
    assert_equal [ 0, "value" ], [ held.card_index, held.slot ]
    assert_equal @org.id, held.organisation_id
    assert_enqueued_with(job: ScreenHeldTextsJob, args: [ resp.id ])
    assert_not_includes resp.answers.to_json, "matters"
  end

  test "contact details are scrubbed before the text is held anywhere" do
    s = survey_with(OPEN)

    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Write to me at kid@example.com please" } })

    held = resp.held_texts.sole
    assert_equal "Write to me at [removed] please", held.text
    assert_equal({ "email" => 1 }, held.scrub_hits)
    assert_not_includes HeldText.connection.select_value("SELECT text FROM held_texts WHERE id = #{held.id}").to_s, "example.com"
  end

  test "an Other write-in is held the same way; the choice stays" do
    s = survey_with([ { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B], "allow_other" => true } ])

    resp = post_answers!(s, { "0" => { "type" => "multiple_choice", "value" => nil, "other" => "Something else" } })

    assert_equal({ "type" => "multiple_choice", "value" => nil, "other" => nil, "held" => { "other" => true } }, resp.answers["0"])
    assert resp.answered?
    assert_equal [ "other", "Something else" ], resp.held_texts.sole.values_at(:slot, :text)
  end

  test "a replayed write finds its row instead of holding the text twice" do
    s = survey_with(OPEN)
    token = SecureRandom.uuid
    payload = { "0" => { "type" => "open_ended", "value" => "Same words" } }

    post_answers!(s, payload, token: token)
    resp = post_answers!(s, payload, token: token, path: :submit)

    assert_equal 1, resp.held_texts.count
    assert_equal({ "value" => true }, resp.answers["0"]["held"])
    assert_equal "completed", resp.status
  end

  test "a changed answer supersedes the earlier text" do
    s = survey_with(OPEN)
    token = SecureRandom.uuid

    post_answers!(s, { "0" => { "type" => "open_ended", "value" => "First thought" } }, token: token)
    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Second thought" } }, token: token)

    first, second = resp.held_texts.order(:id)
    assert_equal "superseded", first.status
    assert first.purge_after.present?
    assert_equal [ "pending", "Second thought" ], [ second.status, second.text ]
    assert_equal({ "value" => true }, resp.answers["0"]["held"])
  end

  test "a released text passes straight through on the next replay" do
    s = survey_with(OPEN)
    token = SecureRandom.uuid
    payload = { "0" => { "type" => "open_ended", "value" => "Fine words" } }
    resp = post_answers!(s, payload, token: token)
    resp.held_texts.sole.release!(auto: true)

    resp = post_answers!(s, payload, token: token, path: :submit)

    assert_equal "Fine words", resp.answers["0"]["value"]
    assert_not resp.answers["0"].key?("held")
    assert_equal 1, resp.held_texts.count
    assert_equal "released", resp.held_texts.sole.status
  end

  test "a removed text stays out on replay" do
    s = survey_with(OPEN)
    token = SecureRandom.uuid
    payload = { "0" => { "type" => "open_ended", "value" => "12 Acacia Avenue" } }
    resp = post_answers!(s, payload, token: token)
    resp.held_texts.sole.remove!(auto: true)

    resp = post_answers!(s, payload, token: token, path: :submit)

    assert_nil resp.answers["0"]["value"]
    assert_equal({ "value" => "removed" }, resp.answers["0"]["held"])
    assert_equal 1, resp.held_texts.count
  end

  test "the player cannot plant a marker" do
    s = survey_with(OPEN)

    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => nil, "held" => { "value" => true } } })

    assert_not resp.answers["0"].key?("held")
    assert_not resp.answered?
    assert_empty resp.held_texts
  end

  test "No going back pins the held marker against a later different text" do
    s = survey_with(OPEN, no_going_back: true)
    token = SecureRandom.uuid

    post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Committed" } }, token: token)
    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Changed my mind" } }, token: token)

    assert_equal 1, resp.held_texts.count
    assert_equal "Committed", resp.held_texts.sole.text
    assert_equal({ "value" => true }, resp.answers["0"]["held"])
  end

  # ── What is NOT held ──────────────────────────────────────────────────────

  test "structured demographic picks are stored as before" do
    s = survey_with([
      { "type" => "open_ended", "text" => "Where?", "demographic" => true, "input" => "location" },
      { "type" => "open_ended", "text" => "Born?", "demographic" => true, "input" => "month" }
    ])

    resp = post_answers!(s, {
      "0" => { "type" => "open_ended", "value" => "GB|Kent" },
      "1" => { "type" => "open_ended", "value" => "1999-04" }
    })

    assert_equal "GB|Kent", resp.answers["0"]["value"]
    assert_equal "GB", resp.region_country
    assert_equal "1999-04", resp.answers["1"]["value"]
    assert_equal 1999, resp.demographic_birth_year
    assert_empty resp.held_texts
  end

  test "a correct free-text quiz answer is scored at once; a wrong one is held" do
    s = survey_with([ { "type" => "open_ended", "text" => "Capital of France?", "correct" => [ "Paris" ] } ], quiz: true)

    right = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "paris" } })
    wrong = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Lyon, where my aunt lives" } })

    assert_equal "paris", right.answers["0"]["value"]
    assert_equal 1, right.score
    assert_empty right.held_texts
    assert_nil wrong.answers["0"]["value"]
    assert_equal({ "value" => true }, wrong.answers["0"]["held"])
    assert_equal 0, wrong.score
    assert_equal "Lyon, where my aunt lives", wrong.held_texts.sole.text
  end

  test "the quiz grader's Claude call sees the scrubbed answer, and the wrong answer is then held" do
    s = survey_with([ { "type" => "open_ended", "text" => "Capital of France?", "correct" => [ "Paris" ] } ], quiz: true)
    seen = []
    fake = Object.new
    fake.define_singleton_method(:call) { |**kw| seen << kw[:answer]; false }

    resp = stub_method(QuizAnswerGrader, :new, ->(*_a, **_k) { fake }) do
      token = SecureRandom.uuid
      post grade_survey_path(s.publish_token),
           params: { session_token: token, card_index: 0,
                     answers: { "0" => { "type" => "open_ended", "value" => "Lyon, ask me at kid@example.com" } } }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :success, response.body
      s.responses.find_by!(session_token: token)
    end

    assert_equal [ "Lyon, ask me at [removed]" ], seen, "the email never reaches the grading prompt"
    held = resp.held_texts.sole
    assert_equal "Lyon, ask me at [removed]", held.text
    assert_equal({ "email" => 1 }, held.scrub_hits, "the merge-time scrub's hits reach the held row")
    assert_equal({ "value" => true }, resp.answers["0"]["held"])
    body = JSON.parse(response.body)
    assert body["graded"]
    assert_equal false, body["correct"]
  end

  test "a held answer still earns its flat token award" do
    s = survey_with([ { "type" => "open_ended", "text" => "Why?", "token_award" => { "t1" => 3 } } ],
                    tokenisation_enabled: true, token_types: [ { "id" => "t1", "icon" => "★", "name" => "Stars" } ])

    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Because" } })

    assert_equal({ "t1" => 3 }, resp.token_totals)
    assert_equal({ "value" => true }, resp.answers["0"]["held"])
  end

  test "with the hold switched off the scrub still runs and the text is stored" do
    Moderation.hold_enabled = false
    s = survey_with(OPEN)

    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Ring 020 7946 0958 for details" } })

    assert_equal "Ring [removed] for details", resp.answers["0"]["value"]
    assert_empty resp.held_texts
    assert_no_enqueued_jobs only: ScreenHeldTextsJob
  end

  # ── Everything that reads answers ─────────────────────────────────────────

  test "results totals count a held answer; nothing lists its text" do
    s = survey_with([ OPEN.first,
                      { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B], "allow_other" => true } ])
    post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Held words" },
                       "1" => { "type" => "multiple_choice", "value" => nil, "other" => "Held other" } })
    post_answers!(s, { "1" => { "type" => "multiple_choice", "value" => "A" } })

    open, choice = AGG.build(s.cards, s.responses)

    assert_equal 1, open[:total]
    assert_empty open[:texts]
    assert_equal 1, open[:held]
    assert_equal 2, choice[:total]
    assert_equal({ "A" => 1, "Other" => 1 }, choice[:counts])
    assert_empty choice[:other_texts]
    assert_equal 1, choice[:held]
  end

  test "the CSV export shows a placeholder, never the text" do
    s = survey_with(OPEN)
    export = ResultsExport.allocate
    card = OPEN.first

    assert_equal "[awaiting moderation]",
                 export.send(:format_answer, card, { "type" => "open_ended", "value" => nil, "held" => { "value" => true } })
    assert_equal "[removed by moderation]",
                 export.send(:format_answer, card, { "type" => "open_ended", "value" => nil, "held" => { "value" => "removed" } })
    assert_equal "A; Other: [awaiting moderation]",
                 export.send(:format_answer, { "type" => "multiple_choice" },
                             { "type" => "multiple_choice", "value" => "A", "other" => nil, "held" => { "other" => true } })
    assert_equal "", export.send(:format_answer, card, { "type" => "open_ended", "value" => nil })
    assert s.persisted?
  end

  test "a subject access export includes the held text and where it stands" do
    s = survey_with(OPEN)
    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "My own words" } })

    out = RespondentDataExport.new(survey: s, responses: [ resp ]).call

    held = out["responses"].first["held_answers"].sole
    assert_equal({ "question" => "Why?", "text" => "My own words", "status" => "pending" }, held.except("held_at"))
    assert_empty out["responses"].first.fetch("answers", []), "the answer itself has no text to list yet"
  end

  test "recall never pre-fills a held answer" do
    s = survey_with(OPEN)
    rows = [ { "0" => { "type" => "open_ended", "value" => nil, "held" => { "value" => true } } } ]

    assert_nil RespondentRecall.new(s).send(:agreed_answer, rows, "0")
  end

  test "declining consent deletes the held text with everything else" do
    s = survey_with(OPEN)
    token = SecureRandom.uuid
    resp = post_answers!(s, { "0" => { "type" => "open_ended", "value" => "Given before the gate" } }, token: token)
    assert_equal 1, resp.held_texts.count

    post consent_survey_path(s.publish_token), params: { session_token: token, agreed: false }.to_json,
                                               headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal({}, resp.reload.answers)
    assert_empty resp.held_texts
    assert_not resp.answered?
  end

  test "the request log filters answers and contact fields" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    logged = filter.filter("answers" => { "0" => { "value" => "secret words" } },
                           "contact" => { "email" => "a@b.com" }, "session_token" => "t", "locale" => "en")

    assert_equal "[FILTERED]", logged["answers"]
    assert_equal "[FILTERED]", logged["contact"]
    assert_equal "en", logged["locale"]
  end
end
