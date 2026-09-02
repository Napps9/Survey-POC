require "test_helper"

# The two play rules as settings: off by default, one form each on the Publish
# panel, and — unlike the scoring switches — editable while the Verto is live,
# because No retests is meant to be flipped between waves of a study.
class PlayRulesSettingsTest < ActionDispatch::IntegrationTest
  TOKENS = [ { "id" => "t1", "name" => "Tokens", "icon" => "★" } ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "pr-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "pr-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def survey(**attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ],
                         cards: [ { "type" => "yes_no", "cid" => "q1", "text" => "Q", "options" => %w[Yes No] } ],
                         publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current, **attrs)
  end

  test "both rules are off by default and round-trip through the settings form" do
    s = survey
    assert_not s.no_going_back?, "new behaviour — opt in"
    assert_not s.no_retests?

    post survey_settings_path(s), params: { no_going_back: "1" }
    assert s.reload.no_going_back?
    post survey_settings_path(s), params: { no_retests: "1" }
    assert s.reload.no_retests?
    post survey_settings_path(s), params: { no_retests: "0" }
    assert_not s.reload.no_retests?
  end

  test "both stay editable on a live Verto with responses" do
    s = survey
    s.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                        answers: { "0" => { "type" => "yes_no", "value" => "Yes" } })
    assert s.editing_locked?

    post survey_settings_path(s), params: { no_retests: "1" }
    assert s.reload.no_retests?, "No retests is switched between waves of a live study — it cannot lock"
    post survey_settings_path(s), params: { no_going_back: "1" }
    assert s.reload.no_going_back?
  end

  test "the Publish panel offers both on a plain Verto, with the notes that fit its setup" do
    s = survey
    get survey_path(s)
    assert_select "input[type=checkbox][name='no_going_back']", count: 1
    assert_select "input[type=checkbox][name='no_retests']", count: 1
    assert_select "input[type=checkbox][name='no_retests'][disabled]", false
    assert_match "checked per device only", response.body, "no codes: say what the identity is"
    assert_no_match(/already finished this wave is told so/, response.body)

    s.update!(respondent_code_enabled: true)
    get survey_path(s)
    assert_match "already finished this wave is told so", response.body, "the oracle is named where it is chosen"
    assert_no_match(/checked per device only/, response.body)
    assert_no_match(/Put the respondent-code card first/, response.body)

    s.update!(respondent_code_enabled: false,
              cards: [ { "type" => "respondent_code", "cid" => "rc", "text" => "Code" } ] + s.cards)
    get survey_path(s)
    assert_match "Put the respondent-code card first", response.body
  end

  test "the token back-nav switch is disabled while No going back is on" do
    s = survey(tokenisation_enabled: true, token_types: TOKENS)
    get survey_path(s)
    assert_select "input[name='token_back_nav_enabled'][disabled]", false

    s.update!(no_going_back: true)
    get survey_path(s)
    assert_select "input[name='token_back_nav_enabled'][disabled]", count: 1
    assert_match "Off while No going back is on", response.body
  end

  test "the player page carries the rules" do
    s = survey(no_going_back: true)
    get play_survey_path(s.publish_token)
    assert_select "[data-player-no-going-back-value='true']"
    assert_select "[data-player-no-retests-value='']"

    s.update!(no_going_back: false)
    get play_survey_path(s.publish_token)
    assert_select "[data-player-no-going-back-value='false']"
  end
end
