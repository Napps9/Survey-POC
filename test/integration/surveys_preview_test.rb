require "test_helper"

class SurveysPreviewTest < ActionDispatch::IntegrationTest
  def sign_in_to_org(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Do you like sport?", "options" => [ "Yes", "No" ] }
  ].freeze

  test "preview renders the player for a draft with recording disabled" do
    org = sign_in_to_org("draft")
    s   = org.surveys.create!(title: "Draft", theme: "Draft", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS)

    get preview_survey_path(s)
    assert_response :success
    assert_match 'data-player-progress-url-value=""', response.body
    assert_match 'data-player-submit-url-value=""', response.body
    assert_match "Preview mode", response.body
    assert_match "Exit preview", response.body
    assert_match "Do you like sport?", response.body
  end

  test "preview of a live Verto also keeps recording disabled" do
    org = sign_in_to_org("live")
    s   = org.surveys.create!(title: "Live", theme: "Live", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS,
                              publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get preview_survey_path(s)
    assert_response :success
    assert_match 'data-player-progress-url-value=""', response.body
    assert_match 'data-player-submit-url-value=""', response.body
  end

  test "preview is scoped to the owning organisation" do
    other = Organisation.create!(name: "Other", slug: "other-#{SecureRandom.hex(2)}")
    s     = other.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                  default_locale: "en", locales: [ "en" ], cards: CARDS)
    sign_in_to_org("intruder")

    get preview_survey_path(s)
    assert_response :not_found
  end

  test "public play URL still wires up the recording endpoints" do
    org = sign_in_to_org("play")
    s   = org.surveys.create!(title: "Live", theme: "Live", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS,
                              publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_match submit_survey_url(s.publish_token), response.body
    assert_match progress_survey_url(s.publish_token), response.body
    refute_match "Preview mode", response.body
  end

  test "a signed-out visitor to a published Verto's preview link is forwarded to the public player" do
    # The creator copied /surveys/:id/preview from their address bar and sent it
    # to respondents; a signed-out respondent should land on the real /play link
    # rather than a sign-in wall.
    org   = Organisation.create!(name: "O", slug: "fwd-#{SecureRandom.hex(2)}")
    token = SecureRandom.urlsafe_base64(18)
    s     = org.surveys.create!(title: "Live", theme: "Live", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en" ], cards: CARDS,
                                publish_token: token, published_at: Time.current)

    get preview_survey_path(s)
    assert_redirected_to play_survey_url(token)
  end

  test "the forward preserves an explicit ?lang= from the shared link" do
    org   = Organisation.create!(name: "O", slug: "fwdlang-#{SecureRandom.hex(2)}")
    token = SecureRandom.urlsafe_base64(18)
    s     = org.surveys.create!(title: "Live", theme: "Live", audience_age: "all", key_insight: "x",
                                default_locale: "en", locales: [ "en", "fr" ], cards: CARDS,
                                publish_token: token, published_at: Time.current)

    get preview_survey_path(s, lang: "fr")
    assert_redirected_to play_survey_url(token, lang: "fr")
  end

  test "a signed-out visitor to a draft's preview link still hits the sign-in wall" do
    # A draft has no public player to forward to, so the normal auth flow stands.
    org = Organisation.create!(name: "O", slug: "draftfwd-#{SecureRandom.hex(2)}")
    s   = org.surveys.create!(title: "Draft", theme: "Draft", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS)

    get preview_survey_path(s)
    assert_redirected_to new_session_path
  end

  test "dashboard cards link to the preview" do
    org = sign_in_to_org("dash")
    s   = org.surveys.create!(title: "Card", theme: "Card", audience_age: "all", key_insight: "x",
                              default_locale: "en", locales: [ "en" ], cards: CARDS)

    get root_path
    assert_response :success
    assert_match preview_survey_path(s), response.body
  end
end
