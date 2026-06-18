require "test_helper"

class ConsentGateTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi" },
    { "type" => "yes_no", "text" => "Q", "options" => [ "Yes", "No" ] }
  ].freeze

  def sign_in_org(suffix)
    user = User.create!(name: "U", email_address: "u-#{suffix}-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{suffix}-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
    org
  end

  def published_survey(consent: nil)
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: CARDS, consent_text: consent,
                        publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  test "update_settings stores and clears the consent text" do
    org = sign_in_org("consent-set")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: CARDS,
                            publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post survey_settings_path(s), params: { consent_text: "  You agree to take part.  " }
    assert_equal "You agree to take part.", s.reload.consent_text
    assert s.consent_required?

    post survey_settings_path(s), params: { consent_text: "   " }
    assert_nil s.reload.consent_text
    assert_not s.consent_required?
  end

  test "consent shows as the first card when consent text is set" do
    s = published_survey(consent: "You agree your anonymous answers may be used for research.")

    get play_survey_path(s.publish_token)
    assert_response :success
    # It's a real card in the deck, with agree/decline actions.
    assert_select ".preview-card[data-card-type='consent_card']"
    assert_select ".play-consent-body", /anonymous answers/
    assert_select "button[data-action='click->player#agreeConsent']"
    assert_select "button[data-action='click->player#declineConsent']"
    # Critically it carries NO data-card-index, so it never shifts answer keys
    # (which align to the @survey.cards index).
    assert_select ".preview-card[data-card-type='consent_card'][data-card-index]", false
  end

  test "no consent card when consent text is blank" do
    s = published_survey(consent: nil)

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select ".preview-card[data-card-type='consent_card']", false
  end
end
