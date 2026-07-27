require "test_helper"

# The public player accepts a much older browser than the creator studio.
# ApplicationController's `allow_browser versions: :modern` was turning
# respondents on older phones away with a stock 406 "browser not supported"
# page — indistinguishable, from the outside, from a broken survey link.
class PlayerBrowserSupportTest < ActionDispatch::IntegrationTest
  # Just above the player's floor, well below :modern (Safari 17.2 / Chrome 120).
  SAFARI_17 = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " \
              "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1".freeze
  CHROME_95 = "Mozilla/5.0 (Linux; Android 11; SM-A515F) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/95.0.4638.74 Mobile Safari/537.36".freeze
  # Below the floor — no import maps, so the player genuinely cannot run.
  SAFARI_15 = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 " \
              "(KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1".freeze
  IE_11     = "Mozilla/5.0 (Windows NT 10.0; WOW64; Trident/7.0; rv:11.0) like Gecko".freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "brow-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current
    )
  end

  def get_play(user_agent)
    get play_survey_path(@survey.publish_token), headers: { "User-Agent" => user_agent }
  end

  test "a respondent on Safari 17.0 can open the Verto" do
    get_play SAFARI_17
    assert_response :success
  end

  test "a respondent on Chrome 95 can open the Verto" do
    get_play CHROME_95
    assert_response :success
  end

  test "a respondent on Chrome 95 can submit answers" do
    post submit_survey_path(@survey.publish_token),
         params: { session_token: SecureRandom.uuid,
                   answers: { "0" => { "value" => "Yes" } } }.to_json,
         headers: { "Content-Type" => "application/json", "User-Agent" => CHROME_95 }

    assert_response :success
    assert JSON.parse(response.body)["ok"]
  end

  test "a browser with no import-map support is still turned away honestly" do
    get_play SAFARI_15
    assert_response :not_acceptable

    get_play IE_11
    assert_response :not_acceptable
  end

  test "an unknown or absent user agent is allowed through" do
    get_play ""
    assert_response :success
  end

  test "the creator studio keeps the stricter modern bar" do
    user = User.create!(name: "U", email_address: "brow-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }

    # Same browser the player happily accepts — the studio should not.
    get root_path, headers: { "User-Agent" => SAFARI_17 } # surveys#index
    assert_response :not_acceptable
  end
end
