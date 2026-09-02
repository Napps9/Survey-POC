require "test_helper"

# "No retests" at the HTTP surface: one completed run per identity per wave,
# refused by every write path with one constant body, and never by storing a
# row first. The identity rule itself (code exclusive wherever a code is
# collected, device only as the fallback) is locked by survey_retest_test.
class NoRetestsPlayerTest < ActionDispatch::IntegrationTest
  PLAIN = [ { "type" => "yes_no", "cid" => "q1", "text" => "Q", "options" => %w[Yes No] },
            { "type" => "rating", "cid" => "q2", "text" => "Rate" } ].freeze
  QUIZ  = [ { "type" => "multiple_choice", "cid" => "q1", "text" => "2+2?", "options" => %w[3 4], "correct" => "4" },
            { "type" => "yes_no", "cid" => "q2", "text" => "Q", "options" => %w[Yes No] } ].freeze
  CODE_CARD_DECK = [ { "type" => "yes_no", "cid" => "q1", "text" => "Q", "options" => %w[Yes No] },
                     { "type" => "respondent_code", "cid" => "rc", "text" => "Make up a code" },
                     { "type" => "rating", "cid" => "q3", "text" => "Rate" } ].freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "nrt-#{SecureRandom.hex(3)}")
  end

  def survey(cards: PLAIN, **attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards, no_retests: true,
                         publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
    JSON.parse(response.body)
  end

  def payload(token:, code: nil, key: nil, answers: { "0" => { "type" => "yes_no", "value" => "Yes" } })
    { session_token: token, respondent_code: code, player_key: key, answers: answers }.compact
  end

  def submit!(s, **kw)   = json_post(submit_survey_path(s.publish_token), payload(**kw))
  def progress!(s, **kw) = json_post(progress_survey_path(s.publish_token), payload(**kw))
  def grade!(s, **kw)    = json_post(grade_survey_path(s.publish_token), payload(**kw).merge(card_index: 0))

  def assert_refused(body)
    assert_response :forbidden
    assert_equal false, body["ok"]
    assert_equal "already_played", body["code"]
  end

  test "a second run under the same code in the same wave is refused by every write path" do
    s = survey(respondent_code_enabled: true)
    submit!(s, token: "t1", code: "sam14")
    assert_response :success

    assert_refused submit!(s, token: "t2", code: "sam14")
    assert_refused progress!(s, token: "t3", code: "sam14")
    assert_equal 1, s.responses.count, "a refused run never creates a row"

    quiz   = survey(cards: QUIZ, quiz: true, respondent_code_enabled: true)
    answer = { "0" => { "type" => "multiple_choice", "value" => "4" } }
    grade!(quiz, token: "q1", code: "sam14", answers: answer)
    assert_response :success
    assert_equal quiz.respondent_code_digest("sam14"),
                 quiz.responses.find_by(session_token: "q1").respondent_code_digest,
                 "/grade records the code like every other save (it used to drop it)"
    quiz.responses.find_by(session_token: "q1").update!(status: "completed", completed_at: Time.current)
    assert_refused grade!(quiz, token: "q2", code: "sam14", answers: answer)
  end

  test "the refusal names nothing: no code, digest, wave or count" do
    s = survey(respondent_code_enabled: true)
    s.start_next_wave!(label: "Autumn term")
    submit!(s, token: "t1", code: "sam14")

    body = submit!(s, token: "t2", code: "sam14")
    assert_refused body
    assert_no_match(/sam14/i, response.body)
    assert_no_match(/#{Regexp.escape(s.respondent_code_digest("sam14"))}/, response.body)
    assert_no_match(/autumn|wave/i, response.body)
    assert_equal({ "ok" => false, "code" => "already_played", "error" => "You've already taken this Verto." }, body,
                 "one constant body whichever identity matched")
  end

  test "starting the next wave admits the same code once more — the pre/post-test design" do
    s = survey(respondent_code_enabled: true)
    submit!(s, token: "pre", code: "sam14")

    s.start_next_wave!
    submit!(s, token: "post", code: "sam14")
    assert_response :success
    assert_equal s.current_wave.id, s.responses.find_by(session_token: "post").survey_wave_id

    assert_refused submit!(s, token: "post-again", code: "sam14")
    assert_equal 2, s.responses.count
  end

  test "an unfinished earlier run does not block, and replaying one's own submit is idempotent" do
    s = survey(respondent_code_enabled: true)
    progress!(s, token: "abandoned", code: "sam14")
    assert_response :success

    submit!(s, token: "t2", code: "sam14")
    assert_response :success, "a started row is not a run"

    submit!(s, token: "t2", code: "sam14")
    assert_response :success, "the offline queue replays the same submit; it must not be refused"
    assert_equal 2, s.responses.count
  end

  test "a code arriving mid-deck on an already persisted row is still checked" do
    s = survey(cards: CODE_CARD_DECK)
    assert_equal "code", s.retest_basis
    s.responses.create!(session_token: "done", status: "completed", answered: true, completed_at: Time.current,
                        respondent_code_digest: s.respondent_code_digest("sam14"))

    progress!(s, token: "t2") # the first card, no code yet — persisted as started
    assert_response :success
    row = s.responses.find_by(session_token: "t2")
    assert_nil row.respondent_code_digest

    assert_refused progress!(s, token: "t2", code: "sam14")
    assert_nil row.reload.respondent_code_digest, "the refused write attaches nothing"
    assert_equal "started", row.status
  end

  test "without codes the device is the identity, and its digest is recorded only then" do
    s = survey
    assert_equal "device", s.retest_basis
    submit!(s, token: "t1", key: "phone-1")
    assert_response :success
    assert s.responses.find_by(session_token: "t1").player_key_digest.present?,
           "no board, no contact form — the device digest exists because No retests needs it"

    assert_refused submit!(s, token: "t2", key: "phone-1")
    submit!(s, token: "t3", key: "phone-2")
    assert_response :success

    off = survey(no_retests: false)
    submit!(off, token: "o1", key: "phone-1")
    assert_nil off.responses.find_by(session_token: "o1").player_key_digest,
               "rule off: nothing is collected that no feature needs"
  end

  test "on a code-collecting Verto the device never participates — the shared classroom tablet" do
    s = survey(respondent_code_enabled: true)
    submit!(s, token: "a", code: "pupil-a", key: "tablet-3")
    assert_response :success

    submit!(s, token: "b", code: "pupil-b", key: "tablet-3")
    assert_response :success, "pupil B's own code on the same device is a first run"
    assert_refused submit!(s, token: "a2", code: "pupil-a", key: "tablet-9")
    assert_nil s.responses.find_by(session_token: "a").player_key_digest,
               "a code-collecting Verto mints no per-device digest for this rule"
  end

  test "declining consent drops the identity, so re-agreeing is a fresh first run" do
    s = survey(respondent_code_enabled: true)
    submit!(s, token: "t1", code: "sam14")
    json_post consent_survey_path(s.publish_token), session_token: "t1", agreed: false
    assert_response :success

    submit!(s, token: "t2", code: "sam14")
    assert_response :success
  end

  test "with the rule off a second run is stored, as it always was" do
    s = survey(no_retests: false, respondent_code_enabled: true)
    submit!(s, token: "t1", code: "sam14")
    submit!(s, token: "t2", code: "sam14")
    assert_response :success
    assert_equal 2, s.responses.count
  end
end
