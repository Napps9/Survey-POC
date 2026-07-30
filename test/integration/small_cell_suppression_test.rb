require "test_helper"

# P1-14. #regions has enforced a minimum sample size since it was written, but
# #results and #scores did not — so on a Verto with one or two responders, the
# "comparison" a respondent is shown after finishing IS the other respondent's
# answers, attributable to them by anyone who knows who else was asked. Both
# endpoints are public and answer anyone holding the play link.
class SmallCellSuppressionTest < ActionDispatch::IntegrationTest
  MIN = Response::MIN_REGION_SAMPLE_SIZE

  CARDS = [
    { "type" => "yes_no", "cid" => "c_a", "text" => "Do you feel safe?", "options" => %w[Yes No] }
  ].freeze

  QUIZ_CARDS = [
    { "type" => "multiple_choice", "cid" => "q_a", "text" => "Capital of France?",
      "options" => %w[Paris Rome], "correct" => "Paris" }
  ].freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "scs-#{SecureRandom.hex(3)}")
  end

  def live(cards, **attrs)
    s = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults", key_insight: "k",
                             default_locale: "en", locales: [ "en" ], cards: cards, **attrs)
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    s.reload
  end

  def add_responses(survey, count, quiz: false)
    count.times do |i|
      attrs = { session_token: SecureRandom.uuid, answered: true, status: "completed",
                answers: { "0" => { "type" => quiz ? "multiple_choice" : "yes_no",
                                    "value" => i.even? ? (quiz ? "Paris" : "Yes") : (quiz ? "Rome" : "No") } } }
      attrs.merge!(score: i.even? ? 1 : 0, quiz_max: 1) if quiz
      survey.responses.create!(**attrs)
    end
  end

  # ── #results ────────────────────────────────────────────────────────────

  test "the answer comparison is withheld below the threshold" do
    survey = live(CARDS, show_results_comparison: true)
    add_responses(survey, MIN - 1)

    get player_results_path(survey.publish_token)
    body = JSON.parse(response.body)

    assert_equal true, body["ok"]
    assert_equal true, body["suppressed"]
    assert_empty body["results"], "no per-answer rows may leak below the threshold"
  end

  test "a single responder cannot read the one other person's answers" do
    # The worst case, and the reason this exists.
    survey = live(CARDS, show_results_comparison: true)
    add_responses(survey, 1)

    get player_results_path(survey.publish_token)
    body = JSON.parse(response.body)
    assert_equal true, body["suppressed"]
    assert_empty body["results"]
    assert_not_includes response.body, "Do you feel safe?"
  end

  test "the comparison is returned once the threshold is met" do
    survey = live(CARDS, show_results_comparison: true)
    add_responses(survey, MIN)

    get player_results_path(survey.publish_token)
    body = JSON.parse(response.body)

    assert_nil body["suppressed"]
    assert_equal MIN, body["total_responses"]
    assert body["results"].any?, "at the threshold the comparison should be available"
  end

  test "suppression does not turn into an error the player shows as a failure" do
    # ok:false would render "Couldn't load — try again", which is a lie: nothing
    # failed. The player needs to say why instead.
    survey = live(CARDS, show_results_comparison: true)
    add_responses(survey, 1)

    get player_results_path(survey.publish_token)
    assert_response :success
    assert_equal true, JSON.parse(response.body)["ok"]
  end

  test "the comparison toggle still gates ahead of suppression" do
    survey = live(CARDS, show_results_comparison: false)
    add_responses(survey, MIN)

    get player_results_path(survey.publish_token)
    assert_response :forbidden
  end

  # ── #scores ─────────────────────────────────────────────────────────────

  test "quiz scores are withheld below the threshold" do
    survey = live(QUIZ_CARDS, quiz: true)
    add_responses(survey, MIN - 1, quiz: true)

    get player_scores_path(survey.publish_token)
    body = JSON.parse(response.body)

    assert_equal true, body["suppressed"]
    assert_empty body["distribution"]
    assert_empty body["per_question"], "a per-question correct rate over 4 people is their answer sheet"
  end

  test "a per-question correct rate does not leak the one other taker's paper" do
    survey = live(QUIZ_CARDS, quiz: true)
    add_responses(survey, 1, quiz: true)

    get player_scores_path(survey.publish_token)
    assert_not_includes response.body, "Capital of France?"
  end

  test "quiz scores are returned once the threshold is met" do
    survey = live(QUIZ_CARDS, quiz: true)
    add_responses(survey, MIN, quiz: true)

    get player_scores_path(survey.publish_token)
    body = JSON.parse(response.body)

    assert_nil body["suppressed"]
    assert_equal MIN, body["total"]
    assert body["per_question"].any?
  end

  # ── #regions, unchanged ─────────────────────────────────────────────────

  test "regions still suppresses small countries, as it always did" do
    survey = live(CARDS, regions_enabled: true)
    (MIN - 1).times do
      survey.responses.create!(session_token: SecureRandom.uuid, answered: true, status: "completed",
                               region_country: "GB", region_label: "London",
                               answers: { "0" => { "type" => "yes_no", "value" => "Yes" } })
    end

    get player_regions_path(survey.publish_token)
    assert_empty JSON.parse(response.body)["regions"]
  end
end
