require "test_helper"

class CookieConsentBannerTest < ActionDispatch::IntegrationTest
  def published_survey
    org = Organisation.create!(name: "Cookie Co", slug: "cookie-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      publish_token: SecureRandom.hex(8)
    )
    survey
  end

  test "the player renders the cookie-consent banner, and never loads Clarity unconditionally" do
    get play_survey_path(published_survey.publish_token)
    assert_response :success

    assert_select "[data-controller='cookie-consent']"
    assert_select "[data-cookie-consent-clarity-id-value='wyq1mb82dv']"

    # The old unconditional inline loader must be gone — Clarity is now only
    # ever injected client-side by cookie_consent_controller.js#_activateAnalytics,
    # after consent.
    assert_no_match(/clarity\.ms\/tag/, response.body)
  end

  test "Test Mode renders no banner — it records nothing, so there is nothing to consent to" do
    survey = published_survey
    survey.update!(test_token: SecureRandom.hex(8))

    get test_survey_path(survey.test_token)
    assert_response :success

    assert_select "[data-controller='cookie-consent']", false,
      "Test Mode has no analytics to gate, and the link is embeddable — a banner there only blocks the first tap"
    assert_no_match(/clarity\.ms/, response.body)
  end

  test "the sign-in page also renders the cookie-consent banner (site-wide, not just the player)" do
    get new_session_path
    assert_response :success
    assert_select "[data-controller='cookie-consent']"
  end
end
