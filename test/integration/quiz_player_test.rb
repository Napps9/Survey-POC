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

  def with_fake_grader(correct)
    fake = Object.new
    fake.define_singleton_method(:call) { |**_kw| correct }
    QuizAnswerGrader.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    QuizAnswerGrader.singleton_class.remove_method(:new)
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

  test "the initial player page never reveals which option is correct" do
    s = quiz_survey
    get play_survey_path(s.publish_token)
    assert_response :success
    # data-correct="true" is an editor-only marker (see _card_component.html.erb,
    # mark_correct) — asserting it never renders "true" here guards against it
    # (or its outline styling) leaking the answer before the respondent has
    # even picked one. Every option renders data-correct="false" outside the
    # editor, so this checks the specific leaking value, not the attribute.
    refute_match('data-correct="true"', response.body)
  end

  test "grade uses AI to judge a near-miss open_ended answer as correct and normalizes it" do
    s = quiz_survey
    body = with_fake_grader(true) do
      json_post grade_survey_path(s.publish_token),
                session_token: "near", card_index: 3,
                answers: { "3" => { "type" => "open_ended", "value" => "it is four" } }
    end
    assert body["graded"]
    assert body["correct"], "the AI judged this a genuine match"
    stored = s.responses.find_by(session_token: "near").answers["3"]["value"]
    assert_equal "4", stored, "normalized to the accepted wording so later recomputation is a free exact match"
  end

  test "grade only asks the AI once — a repeat call reuses the locked verdict" do
    s = quiz_survey
    with_fake_grader(true) do
      json_post grade_survey_path(s.publish_token),
                session_token: "once", card_index: 3,
                answers: { "3" => { "type" => "open_ended", "value" => "it is four" } }
    end

    # A second grade call for the same (now-locked) card must NOT ask again —
    # this fake would flip the verdict to wrong if it were ever invoked.
    body = with_fake_grader(false) do
      json_post grade_survey_path(s.publish_token),
                session_token: "once", card_index: 3,
                answers: { "3" => { "type" => "open_ended", "value" => "it is four" } }
    end
    assert body["correct"], "the original AI-confirmed verdict must stand"
  end

  test "an AI grading failure leaves the exact-match verdict standing, never 500s" do
    s = quiz_survey
    boom = Object.new
    boom.define_singleton_method(:call) { |**_kw| raise "network down" }
    QuizAnswerGrader.define_singleton_method(:new) { |*| boom }
    body = json_post grade_survey_path(s.publish_token),
                     session_token: "err", card_index: 3,
                     answers: { "3" => { "type" => "open_ended", "value" => "it is four" } }
    assert_response :success
    refute body["correct"], "falls back to the plain exact-match verdict"
  ensure
    QuizAnswerGrader.singleton_class.remove_method(:new)
  end

  # #grade is public and unauthenticated, so its Claude call is bounded by a
  # slot pool. These pin the two halves of that bound: the AI is skipped when
  # the process is saturated, and the slot always comes back afterwards.
  def with_pool_drained
    pool = PlayerController::AI_GRADE_POOL
    held = []
    held << true while pool.acquire
    yield
  ensure
    held.size.times { pool.release }
  end

  test "a saturated AI pool still saves the answer — it only skips the refinement" do
    s = quiz_survey
    body = with_pool_drained do
      # This fake would call the near-miss correct if it were ever reached.
      with_fake_grader(true) do
        json_post grade_survey_path(s.publish_token),
                  session_token: "busy", card_index: 3,
                  answers: { "3" => { "type" => "open_ended", "value" => "it is four" } }
      end
    end

    assert_response :success
    refute body["correct"], "with no slot free the respondent keeps the exact-match verdict"

    # The assertion that matters: bounding the AI call must not cost the
    # respondent their answer. A bulkhead around the whole action would
    # short-circuit before the save and lose this.
    stored = s.responses.find_by(session_token: "busy")
    assert stored, "the response row must still be created"
    assert_equal "it is four", stored.answers["3"]["value"], "the answer is persisted verbatim"
  end

  test "the AI slot is released after a call, so the next respondent still gets judged" do
    s = quiz_survey
    before = PlayerController::AI_GRADE_POOL.available

    with_fake_grader(true) do
      json_post grade_survey_path(s.publish_token),
                session_token: "first", card_index: 3,
                answers: { "3" => { "type" => "open_ended", "value" => "it is four" } }
    end
    assert_equal before, PlayerController::AI_GRADE_POOL.available, "the slot came back"

    body = with_fake_grader(true) do
      json_post grade_survey_path(s.publish_token),
                session_token: "second", card_index: 3,
                answers: { "3" => { "type" => "open_ended", "value" => "it is four" } }
    end
    assert body["correct"], "a later respondent still reaches the AI"
  end

  test "the AI slot is released even when the grader raises" do
    s = quiz_survey
    before = PlayerController::AI_GRADE_POOL.available
    boom = Object.new
    boom.define_singleton_method(:call) { |**_kw| raise "network down" }
    QuizAnswerGrader.define_singleton_method(:new) { |*| boom }

    json_post grade_survey_path(s.publish_token),
              session_token: "raise", card_index: 3,
              answers: { "3" => { "type" => "open_ended", "value" => "it is four" } }

    assert_response :success
    assert_equal before, PlayerController::AI_GRADE_POOL.available,
                 "a leaked slot would shrink the pool permanently until restart"
  ensure
    QuizAnswerGrader.singleton_class.remove_method(:new)
  end

  test "grade and scores are forbidden for a non-quiz Verto" do
    s = quiz_survey(quiz: false)
    json_post grade_survey_path(s.publish_token), session_token: "x", card_index: 1, answers: {}
    assert_response :forbidden
    get player_scores_path(s.publish_token)
    assert_response :forbidden
  end

  # Quiz score comparison and general answer comparison are independent
  # settings — a creator can turn on either or both. They used to render as
  # two separate "compare" CTAs/panels on the thank-you screen; there must
  # now be exactly one of each, with whichever section(s) apply inside.
  test "quiz mode alone renders one compare button with only the scores section" do
    s = quiz_survey(quiz: true)
    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "[data-player-target='compareBtn']", 1
    assert_select "[data-player-target='comparePanel']", 1
    assert_select "[data-player-target='scoresSection']", 1
    assert_select "[data-player-target='comparisonSection']", 0
  end

  test "results comparison alone renders one compare button with only the comparison section" do
    s = quiz_survey(quiz: false)
    s.update!(show_results_comparison: true)
    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "[data-player-target='compareBtn']", 1
    assert_select "[data-player-target='comparePanel']", 1
    assert_select "[data-player-target='scoresSection']", 0
    assert_select "[data-player-target='comparisonSection']", 1
  end

  test "quiz mode and results comparison together render one button with both sections" do
    s = quiz_survey(quiz: true)
    s.update!(show_results_comparison: true)
    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "[data-player-target='compareBtn']", 1
    assert_select "[data-player-target='comparePanel']", 1
    assert_select "[data-player-target='scoresSection']", 1
    assert_select "[data-player-target='comparisonSection']", 1
  end

  test "neither setting renders no compare button at all" do
    s = quiz_survey(quiz: false)
    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select "[data-player-target='compareBtn']", 0
    assert_select "[data-player-target='comparePanel']", 0
  end

  # A multilingual quiz must reveal its answer feedback in the language the
  # respondent is reading. The correct ANSWER stays canonical on purpose — the
  # player matches it against the stored option values to tint right/wrong.
  test "grade returns the explanation in the respondent's language" do
    fr_cards = [
      CARDS[0],
      CARDS[1].merge(
        "i18n" => { "fr" => {
          "text"        => "Capitale de la France ?",
          "options"     => %w[Paris Londres Berlin],
          "explanation" => "Paris est la capitale depuis 987."
        } }
      )
    ]
    s = quiz_survey(cards: fr_cards)
    s.update!(locales: %w[en fr])

    body = json_post grade_survey_path(s.publish_token),
                     session_token: "fr1", card_index: 1, locale: "fr",
                     answers: { "1" => { "type" => "multiple_choice", "value" => "Paris" } }

    assert_response :success
    assert_equal "Paris est la capitale depuis 987.", body["explanation"]
    assert_equal "Paris", body["correct_answer"], "canonical, so option tinting still matches"
  end

  test "grade falls back to the source explanation when a locale has none" do
    s = quiz_survey
    s.update!(locales: %w[en fr])

    body = json_post grade_survey_path(s.publish_token),
                     session_token: "fr2", card_index: 1, locale: "fr",
                     answers: { "1" => { "type" => "multiple_choice", "value" => "Paris" } }

    assert_equal "Paris has been the capital since 987.", body["explanation"]
  end
end
