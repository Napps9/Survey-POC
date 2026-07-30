require "test_helper"

# The post-finish comparison charts (player_controller.js) are driven entirely by
# this JSON endpoint, so lock its shape: a submitted answer must round-trip into
# the aggregated results the charts render.
class PlayerResultsEndpointTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "multiple_choice", "text" => "Favourite colour?", "options" => [ "Red", "Blue" ] }
  ].freeze

  def comparison_survey
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS,
                        show_results_comparison: true,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  # Small-cell suppression (P1-14) withholds the comparison below
  # Response::MIN_REGION_SAMPLE_SIZE responders. These tests are about the SHAPE
  # of the payload, not about small samples, so they pad past the threshold.
  # Fillers answer "Blue" so a test asserting on "Red" counts still reads clearly.
  def pad_past_threshold(survey, answer: "Blue")
    (Response::MIN_REGION_SAMPLE_SIZE - survey.responses.where(answered: true).count).times do
      survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                               answers: { "1" => { "type" => "multiple_choice", "value" => answer } })
    end
  end

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
  end

  test "a submitted answer round-trips into the results contract the charts render" do
    s = comparison_survey

    json_post submit_survey_path(s.publish_token),
              session_token: SecureRandom.uuid,
              answers: { "1" => { "type" => "multiple_choice", "value" => "Red" } }
    assert_response :success
    pad_past_threshold(s)

    get player_results_path(s.publish_token)
    assert_response :success
    body = JSON.parse(response.body)

    assert body["ok"]
    assert_equal Response::MIN_REGION_SAMPLE_SIZE, body["total_responses"]
    row = body["results"].find { |r| r["type"] == "multiple_choice" }
    assert row, "expected the multiple_choice row in the results"
    assert_equal "Favourite colour?", row["prompt"]
    assert_kind_of Hash, row["counts"]
    assert_equal 1, row["counts"]["Red"]
  end

  test "results include partial responders, not only submitted ones" do
    s = comparison_survey

    # submitted → completed
    json_post submit_survey_path(s.publish_token),
              session_token: SecureRandom.uuid,
              answers: { "1" => { "type" => "multiple_choice", "value" => "Red" } }
    # answered but never submitted → started, must still be counted
    s.responses.create!(session_token: SecureRandom.uuid, status: "started",
                        answers: { "1" => { "type" => "multiple_choice", "value" => "Blue" } })
    # opened, answered nothing → excluded
    s.responses.create!(session_token: SecureRandom.uuid, status: "started", answers: {})
    # Pad with "Red" so the Blue count below still reflects only the partial
    # responder — the thing this test is actually about.
    pad_past_threshold(s, answer: "Red")

    get player_results_path(s.publish_token)
    body = JSON.parse(response.body)
    assert_equal Response::MIN_REGION_SAMPLE_SIZE, body["total_responses"]
    row = body["results"].find { |r| r["type"] == "multiple_choice" }
    assert_equal Response::MIN_REGION_SAMPLE_SIZE - 1, row["counts"]["Red"]
    assert_equal 1, row["counts"]["Blue"], "the answered-but-never-submitted responder still counts"
  end

  test "results endpoint is forbidden when comparison is off" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            show_results_comparison: false,
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get player_results_path(s.publish_token)
    assert_response :forbidden
  end
end
