require "test_helper"

# Tokenisation totals are computed entirely server-side from stored answers
# (never trusted from the client), and — like quiz answers — a token-awarding
# card is locked once answered so a respondent can't go back and change an
# answer to earn more. This locks that contract plus the results-comparison
# fold-in.
class TokenPlayerTest < ActionDispatch::IntegrationTest
  TOKEN_TYPES = [
    { "id" => "gold", "name" => "Gold Coins", "icon" => "🪙" },
    { "id" => "coal", "name" => "Coal", "icon" => "⚫" }
  ].freeze

  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "multiple_choice", "text" => "Pick one",
      "options" => %w[Pizza Salad],
      "tokens" => { "Pizza" => { "gold" => 5 }, "Salad" => { "gold" => 2, "coal" => 1 } } },
    { "type" => "open_ended", "text" => "How do you feel?" }, # unawarded measurement Q
    { "type" => "rating", "text" => "Rate it", "token_award" => { "coal" => 3 } }
  ].freeze

  def tokenised_survey(tokenisation_enabled: true, cards: CARDS, show_results_comparison: false)
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: cards,
                        tokenisation_enabled: tokenisation_enabled, token_types: TOKEN_TYPES,
                        show_results_comparison: show_results_comparison,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def json_post(path, payload)
    post path, params: payload.to_json, headers: { "Content-Type" => "application/json" }
    JSON.parse(response.body)
  end

  test "submit computes and caches token totals from the stored answers" do
    s = tokenised_survey
    body = json_post submit_survey_path(s.publish_token),
                     session_token: "done",
                     answers: {
                       "1" => { "type" => "multiple_choice", "value" => "Pizza" },
                       "3" => { "type" => "rating", "value" => 4 }
                     }
    assert_equal({ "gold" => 5, "coal" => 3 }, body["token_totals"])
    resp = s.responses.find_by(session_token: "done")
    assert_equal({ "gold" => 5, "coal" => 3 }, resp.token_totals)
  end

  test "token totals ignore anything the client claims and only trust stored answers" do
    s = tokenised_survey
    # No score/total sent by the client at all — the server must compute its
    # own from the answers, exactly like quiz score.
    body = json_post submit_survey_path(s.publish_token),
                     session_token: "trust",
                     answers: { "1" => { "type" => "multiple_choice", "value" => "Salad" } }
    assert_equal({ "gold" => 2, "coal" => 1 }, body["token_totals"])
  end

  test "a token-awarding card is locked once answered — it can't be changed afterwards" do
    s = tokenised_survey
    json_post progress_survey_path(s.publish_token),
              session_token: "lock",
              answers: { "1" => { "type" => "multiple_choice", "value" => "Pizza" } }

    # Try to overwrite the now-locked card with a different (higher-value) answer.
    body = json_post submit_survey_path(s.publish_token),
                     session_token: "lock",
                     answers: { "1" => { "type" => "multiple_choice", "value" => "Salad" } }

    stored = s.responses.find_by(session_token: "lock").answers["1"]["value"]
    assert_equal "Pizza", stored, "the original answer must stand"
    assert_equal({ "gold" => 5, "coal" => 0 }, body["token_totals"])
  end

  test "a choice card set to completion mode awards a flat amount regardless of which option was picked" do
    s = tokenised_survey(cards: CARDS + [
      { "type" => "select_many", "text" => "Which worry you most?", "options" => %w[Unemployment Debt],
        "token_award_mode" => "completion", "token_award" => { "gold" => 4 } }
    ])
    body = json_post submit_survey_path(s.publish_token),
                     session_token: "flat",
                     answers: { "4" => { "type" => "select_many", "value" => %w[Debt] } }
    # 4 gold from the completion-mode card, nothing from the untouched cards.
    assert_equal({ "gold" => 4, "coal" => 0 }, body["token_totals"])
  end

  test "a card with no token config stays freely editable in a tokenised Verto" do
    s = tokenised_survey
    json_post progress_survey_path(s.publish_token),
              session_token: "measurement",
              answers: { "2" => { "type" => "open_ended", "value" => "great" } }
    json_post submit_survey_path(s.publish_token),
              session_token: "measurement",
              answers: { "2" => { "type" => "open_ended", "value" => "changed my mind" } }

    stored = s.responses.find_by(session_token: "measurement").answers["2"]["value"]
    assert_equal "changed my mind", stored
  end

  test "token_totals is absent for a non-tokenised Verto" do
    s = tokenised_survey(tokenisation_enabled: false)
    body = json_post submit_survey_path(s.publish_token),
                     session_token: "off",
                     answers: { "1" => { "type" => "multiple_choice", "value" => "Pizza" } }
    refute body.key?("token_totals")
    assert_equal({}, s.responses.find_by(session_token: "off").token_totals)
  end

  test "results folds a token-total comparison row in per token type, gated on show_results_comparison" do
    s = tokenised_survey(show_results_comparison: true)
    json_post submit_survey_path(s.publish_token), session_token: "a",
              answers: { "1" => { "value" => "Pizza" } } # 5 gold
    json_post submit_survey_path(s.publish_token), session_token: "b",
              answers: { "1" => { "value" => "Salad" } } # 2 gold, 1 coal

    get player_results_path(s.publish_token)
    body = JSON.parse(response.body)
    assert body["ok"]

    gold_row = body["results"].find { |r| r["type"] == "token_total" && r["token_id"] == "gold" }
    assert gold_row, "expected a synthetic gold token_total row"
    assert_equal({ "5" => 1, "2" => 1 }, gold_row["counts"])
    assert_equal 2, gold_row["total"]
  end

  test "results omits token_total rows when show_results_comparison is off" do
    s = tokenised_survey(show_results_comparison: false)
    get player_results_path(s.publish_token)
    assert_response :forbidden
  end

  test "results omits token_total rows for a non-tokenised Verto even with comparison on" do
    s = tokenised_survey(tokenisation_enabled: false, show_results_comparison: true)
    get player_results_path(s.publish_token)
    body = JSON.parse(response.body)
    refute body["results"].any? { |r| r["type"] == "token_total" }
  end
end
