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

  COAL = { "id" => "t2", "icon" => "⚫", "name" => "Coal" }.freeze

  test "the ranking basis round-trips while a draft, normalises an unknown id, and locks once live" do
    s = tokenised(publish_token: nil, published_at: nil, leaderboard_enabled: true, token_types: TYPES + [ COAL ])
    assert_equal "all", s.leaderboard_rank_by, "the sum of everything — the original board"

    post survey_settings_path(s), params: { leaderboard_rank_by: "t2" }
    assert_equal "t2", s.reload.leaderboard_rank_by
    post survey_settings_path(s), params: { leaderboard_rank_by: "diamonds" }
    assert_equal "all", s.reload.leaderboard_rank_by, "an unknown id falls back to all points, never errors"

    post survey_settings_path(s), params: { leaderboard_rank_by: "t2" }
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    post survey_settings_path(s), params: { leaderboard_rank_by: "all" }
    follow_redirect!
    assert_equal "t2", s.reload.leaderboard_rank_by, "changing the basis re-ranks standings respondents were shown"
  end

  test "the Rank-by radios appear only with two or more types, and lock with the policy" do
    one_type = tokenised(publish_token: nil, published_at: nil, leaderboard_enabled: true)
    get survey_path(one_type)
    assert_select "input[name='leaderboard_rank_by']", false, "one type: the sum and the type are the same order"

    s = tokenised(publish_token: nil, published_at: nil, leaderboard_enabled: true, token_types: TYPES + [ COAL ])
    get survey_path(s)
    assert_select "input[name='leaderboard_rank_by']", count: 3
    assert_select "input[name='leaderboard_rank_by'][value='all'][checked]", count: 1
    assert_match "⚫ Coal", response.body
    assert_select "input[name='leaderboard_rank_by'][disabled]", false

    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                        answers: { "0" => { "type" => "yes_no", "value" => "Yes" } })
    get survey_path(s)
    assert_select "input[name='leaderboard_rank_by'][disabled]", count: 3
    assert_select "input[name='leaderboard_retake_policy']", { count: 3 }, "the policy radios are untouched"
  end

  test "removing the ranked type from a draft falls back to all points" do
    s = tokenised(publish_token: nil, published_at: nil, token_types: TYPES + [ COAL ], leaderboard_rank_by: "t2")
    assert_equal "t2", s.leaderboard_rank_by

    s.update!(token_types: TYPES)
    assert_equal "all", s.reload.leaderboard_rank_by
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
    assert_match "First run counts", response.body, "the old 'No redos' now describes scoring only"
    assert_match "Whether they can play again at all is set under Publish", response.body

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
