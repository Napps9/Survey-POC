require "test_helper"

# The leaderboard's creator settings: which side of the live-lock line each
# one sits on, and how unknown input degrades. The board itself is covered by
# leaderboard_player_test; this locks the editing contract.
class LeaderboardSettingsTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ],
      "tokens" => { "Yes" => { "t1" => 5 } } }
  ].freeze
  TYPES = [ { "id" => "t1", "icon" => "⭐", "name" => "Stars" } ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "lbs-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "lbs-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def tokenised(**attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                         tokenisation_enabled: true, token_types: TYPES,
                         publish_token: SecureRandom.urlsafe_base64(18),
                         published_at: Time.current, **attrs)
  end

  test "the board defaults off and the policy defaults to accumulate" do
    s = tokenised
    assert_not s.leaderboard_enabled?, "new feature — opt in, or existing Vertos change unannounced"
    assert_equal "accumulate", s.leaderboard_retake_policy,
      "the most game-like reading of a retake, and the least surprising"
  end

  test "the toggle stays editable on a live Verto" do
    s = tokenised
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                        answers: { "0" => { "type" => "yes_no", "value" => "Yes" } })
    assert s.editing_locked?

    post survey_settings_path(s), params: { leaderboard_enabled: "1", return_tab: "tokens" }
    assert_redirected_to survey_path(s, tab: "tokens")
    assert s.reload.leaderboard_enabled?, "show/hide is presentation — the standings exist either way"
  end

  test "the retake policy locks once the Verto is live, like the scoring switches" do
    s = tokenised(publish_token: nil, published_at: nil, leaderboard_enabled: true)
    post survey_settings_path(s), params: { leaderboard_retake_policy: "no_redo" }
    assert_equal "no_redo", s.reload.leaderboard_retake_policy, "editable while a draft"

    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    post survey_settings_path(s), params: { leaderboard_retake_policy: "restart" }
    follow_redirect!
    assert_equal "no_redo", s.reload.leaderboard_retake_policy,
      "flipping the policy rewrites standings respondents were already shown"
  end

  test "an unknown policy normalizes to the default rather than erroring" do
    s = tokenised(publish_token: nil, published_at: nil,
                  leaderboard_enabled: true, leaderboard_retake_policy: "no_redo")
    post survey_settings_path(s), params: { leaderboard_retake_policy: "honour_system" }
    assert_equal "accumulate", s.reload.leaderboard_retake_policy
  end

  test "the editor shows the leaderboard block only on a tokenised Verto" do
    s = tokenised(publish_token: nil, published_at: nil, leaderboard_enabled: true)
    get survey_path(s)
    assert_select "input[name='leaderboard_enabled']"
    assert_select "input[name='leaderboard_retake_policy']", count: 3

    plain = tokenised(publish_token: nil, published_at: nil, tokenisation_enabled: false)
    get survey_path(plain)
    assert_select "input[name='leaderboard_enabled']", false,
      "no tokens, nothing to rank — the block would be a dead switch"
  end

  test "the policy radios render disabled once the Verto is live-locked" do
    s = tokenised(leaderboard_enabled: true)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                        answers: { "0" => { "type" => "yes_no", "value" => "Yes" } })

    get survey_path(s)
    assert_select "input[name='leaderboard_retake_policy'][disabled]", count: 3
  end
end
