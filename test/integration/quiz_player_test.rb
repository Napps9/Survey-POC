require "test_helper"

# The quiz player is driven by server-graded endpoints: grade (per-card verdict
# + running score), quiz_state (refresh-proof rehydrate) and scores (how you
# compare). This locks their contract and the no-redo anti-cheat.
class QuizPlayerTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "multiple_choice", "text" => "Capital of France?",
      "options" => %w[Paris London Berlin], "correct" => "Paris",
      "explanation" => "Paris has been the capital since 987." },
    { "type" => "open_ended", "text" => "How do you feel?" }, # ungraded measurement Q
    { "type" => "open_ended", "text" => "2 + 2 = ?", "correct" => [ "4", "four" ] }
  ].freeze

  def quiz_survey(quiz: true, cards: CARDS)
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: cards, quiz: quiz,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
    JSON.parse(response.body)
  end

  test "grade returns a per-card verdict, the correct answer and the running score" do
    s = quiz_survey
    body = json_post grade_survey_path(s.publish_token),
                     session_token: "t1", card_index: 1,
                     answers: { "1" => { "type" => "multiple_choice", "value" => "Paris" } }
    assert_response :success
    assert body["graded"]
    assert body["correct"]
    assert_equal "Paris", body["correct_answer"]
    assert_equal "Paris has been the capital since 987.", body["explanation"]
    assert_equal 1, body["score"]
    assert_equal 2, body["max"], "two graded cards in the deck"
  end

  test "grade marks a wrong answer and still reveals the correct one" do
    s = quiz_survey
    body = json_post grade_survey_path(s.publish_token),
                     session_token: "t2", card_index: 1,
                     answers: { "1" => { "type" => "multiple_choice", "value" => "London" } }
    refute body["correct"]
    assert_equal "Paris", body["correct_answer"]
    assert_equal 0, body["score"]
  end

  test "grade never reveals the answer for a card with no committed answer" do
    s = quiz_survey
    body = json_post grade_survey_path(s.publish_token),
                     session_token: "t3", card_index: 1,
                     answers: { "1" => { "type" => "multiple_choice", "value" => "" } }
    refute body["graded"], "an empty answer can't be used to peek at the correct one"
    assert_nil body["correct_answer"]
  end

  test "a committed quiz answer is locked — it can't be changed afterwards" do
    s = quiz_survey
    json_post grade_survey_path(s.publish_token),
              session_token: "lock", card_index: 1,
              answers: { "1" => { "type" => "multiple_choice", "value" => "Paris" } }

    # Try to overwrite the now-locked card with a different answer.
    body = json_post grade_survey_path(s.publish_token),
                     session_token: "lock", card_index: 1,
                     answers: { "1" => { "type" => "multiple_choice", "value" => "London" } }
    assert body["correct"], "the original correct answer must stand"
    assert_equal 1, body["score"]

    stored = s.responses.find_by(session_token: "lock").answers["1"]["value"]
    assert_equal "Paris", stored
  end

  test "submit returns the final score and caches it on the response" do
    s = quiz_survey
    body = json_post submit_survey_path(s.publish_token),
                     session_token: "done",
                     answers: {
                       "1" => { "type" => "multiple_choice", "value" => "Paris" },
                       "3" => { "type" => "open_ended", "value" => "four" }
                     }
    assert_equal 2, body["score"]
    assert_equal 2, body["max"]
    resp = s.responses.find_by(session_token: "done")
    assert_equal 2, resp.score
    assert_equal 2, resp.quiz_max
  end

  test "quiz_state rehydrates a session's committed graded cards" do
    s = quiz_survey
    json_post grade_survey_path(s.publish_token),
              session_token: "rehydrate", card_index: 1,
              answers: { "1" => { "type" => "multiple_choice", "value" => "Berlin" } }

    get quiz_state_survey_path(s.publish_token), params: { session_token: "rehydrate" }
    body = JSON.parse(response.body)
    assert body["quiz"]
    assert_equal 0, body["score"]
    assert_equal 2, body["max"]
    entry = body["answered"]["1"]
    assert_equal "Berlin", entry["value"]
    refute entry["correct"]
    assert_equal "Paris", entry["correct_answer"]
  end

  test "scores reports the distribution, average and per-question correct rate" do
    s = quiz_survey
    json_post submit_survey_path(s.publish_token), session_token: "a",
              answers: { "1" => { "value" => "Paris" }, "3" => { "value" => "4" } } # 2/2
    json_post submit_survey_path(s.publish_token), session_token: "b",
              answers: { "1" => { "value" => "Paris" }, "3" => { "value" => "nope" } } # 1/2

    get player_scores_path(s.publish_token)
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal 2, body["total"]
    assert_equal 2, body["max"]
    assert_equal 1.5, body["average"]
    counts = body["distribution"].to_h { |d| [ d["score"], d["count"] ] }
    assert_equal({ 0 => 0, 1 => 1, 2 => 1 }, counts)
    q1 = body["per_question"].find { |q| q["index"] == 1 }
    assert_equal 100, q1["pct"], "both got the capital right"
  end

  test "grade and scores are forbidden for a non-quiz Verto" do
    s = quiz_survey(quiz: false)
    json_post grade_survey_path(s.publish_token), session_token: "x", card_index: 1, answers: {}
    assert_response :forbidden
    get player_scores_path(s.publish_token)
    assert_response :forbidden
  end
end
