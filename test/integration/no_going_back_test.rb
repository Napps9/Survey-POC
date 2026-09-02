require "test_helper"

# "No going back", server side. The player hides Back and saves every advance;
# this is the half that has to hold regardless: once a card holds an answer, no
# later write may change it — on ANY Verto, not only a quiz or a tokenised one
# (answered_locking_test covers those two, which were already pinned).
class NoGoingBackTest < ActionDispatch::IntegrationTest
  PLAIN = [ { "type" => "multiple_choice", "cid" => "q1", "text" => "Pick", "options" => %w[A B] },
            { "type" => "yes_no", "cid" => "q2", "text" => "Q", "options" => %w[Yes No] } ].freeze
  QUIZ  = [ { "type" => "multiple_choice", "cid" => "q1", "text" => "2+2?", "options" => %w[3 4], "correct" => "4" },
            { "type" => "multiple_choice", "cid" => "q2", "text" => "Pick", "options" => %w[A B] } ].freeze

  def setup
    @org   = Organisation.create!(name: "O", slug: "ngb-#{SecureRandom.hex(3)}")
    @token = SecureRandom.uuid
  end

  def survey(cards: PLAIN, **attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: cards, no_going_back: true,
                         publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  def write(path, answers, extra = {})
    post path, params: { session_token: @token, answers: answers }.merge(extra).to_json,
               headers: { "Content-Type" => "application/json" }
    assert_response :success
  end

  def stored(s) = s.responses.find_by(session_token: @token).answers

  test "an answered card on a plain Verto is pinned against a later change" do
    s = survey
    write progress_survey_path(s.publish_token), { "0" => { "type" => "multiple_choice", "value" => "A" } }
    write submit_survey_path(s.publish_token), { "0" => { "type" => "multiple_choice", "value" => "B" },
                                                "1" => { "type" => "yes_no", "value" => "Yes" } }

    assert_equal "A", stored(s).dig("0", "value"), "neither quiz nor tokens: the rule alone must pin it"
    assert_equal "Yes", stored(s).dig("1", "value"), "a card answered for the first time takes its value"
  end

  test "a skipped card still accepts a late first answer" do
    s = survey
    write progress_survey_path(s.publish_token), { "0" => { "type" => "multiple_choice", "value" => nil } }
    write submit_survey_path(s.publish_token), { "0" => { "type" => "multiple_choice", "value" => "B" } }
    assert_equal "B", stored(s).dig("0", "value")
  end

  test "with the rule off the later write wins, as it always did on a plain Verto" do
    s = survey(no_going_back: false)
    write progress_survey_path(s.publish_token), { "0" => { "type" => "multiple_choice", "value" => "A" } }
    write submit_survey_path(s.publish_token), { "0" => { "type" => "multiple_choice", "value" => "B" } }
    assert_equal "B", stored(s).dig("0", "value")
  end

  test "on a quiz the pin extends to the ungraded cards, through /grade too" do
    s = survey(cards: QUIZ, quiz: true)
    write grade_survey_path(s.publish_token), { "1" => { "type" => "multiple_choice", "value" => "A" } }, card_index: 1
    write grade_survey_path(s.publish_token), { "1" => { "type" => "multiple_choice", "value" => "B" } }, card_index: 1
    assert_equal "A", stored(s).dig("1", "value"), "graded cards were already pinned; the rule pins the rest"
  end
end
