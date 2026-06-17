require "test_helper"

class ThankYouScreenTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  # Settings are owner-only, so this path signs in.
  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "Acme United", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  # The player is public — created without a session so the fullscreen layout
  # renders the bare respondent view (a signed-in user would get app chrome).
  def published_survey(name: "Acme United")
    org = Organisation.create!(name: name, slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  test "update_settings stores custom thank-you copy and normalises the forward URL" do
    org = sign_in_org("set")
    s   = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS,
                              publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post survey_settings_path(s), params: {
      thankyou_title: "  You're a star ⭐  ",
      thankyou_body:  "We'll be in touch.\nSee you soon.",
      forward_url:    "example.org/thanks"
    }
    s.reload
    assert_equal "You're a star ⭐", s.thankyou_title
    assert_equal "We'll be in touch.\nSee you soon.", s.thankyou_body
    assert_equal "https://example.org/thanks", s.forward_url
    assert s.forward_url?

    # A non-http(s) value clears the CTA rather than storing something unsafe.
    post survey_settings_path(s), params: { forward_url: "javascript:alert(1)" }
    assert_nil s.reload.forward_url
    assert_not s.forward_url?
  end

  test "player renders the custom thank-you copy, a share button, and the website CTA" do
    s = published_survey
    s.update!(thankyou_title: "Big thanks!", thankyou_body: "Line one\nLine two",
              forward_url: "https://acme.example")

    get play_survey_path(s.publish_token)
    assert_response :success

    assert_select ".preview-thankyou-title", text: "Big thanks!"
    assert_select ".preview-thankyou-sub br" # the newline became a line break
    assert_match "Line one", response.body
    assert_match "Line two", response.body

    # Share button is always present; the forward CTA links out safely.
    assert_select "button[data-player-target='shareBtn']"
    assert_select "a[href='https://acme.example'][target='_blank'][rel='noopener']"
  end

  test "without customisation the thank-you falls back to defaults and shows no website CTA" do
    s = published_survey

    get play_survey_path(s.publish_token)
    assert_response :success

    assert_select ".preview-thankyou-title", text: I18n.t("player.thank_you_title")
    assert_select "button[data-player-target='shareBtn']"
    # No forward URL set → no website CTA, but the share button still shows.
    assert_select "[data-player-target='thankyou'] a[target='_blank']", false
  end
end
