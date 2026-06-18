require "test_helper"

# The CSP is enforcing (not report-only) and carries the locked-down directives.
# A public page is enough — the header is applied app-wide by the middleware.
class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  test "an enforcing CSP header is set with the locked-down directives" do
    org = Organisation.create!(name: "CSP Co", slug: "csp-#{SecureRandom.hex(3)}")
    survey = org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" } ],
      publish_token: SecureRandom.hex(8)
    )

    get play_survey_path(survey.publish_token)
    assert_response :success

    # Enforcing header, not the report-only variant.
    csp = response.headers["Content-Security-Policy"]
    assert csp.present?, "Content-Security-Policy header should be set"
    assert_nil response.headers["Content-Security-Policy-Report-Only"]

    assert_includes csp, "default-src 'self'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "base-uri 'self'"
    assert_includes csp, "form-action 'self'"
    assert_includes csp, "frame-ancestors 'self'"
    # Fonts/analytics origins are allowlisted so they don't break.
    assert_includes csp, "https://fonts.gstatic.com"
    assert_includes csp, "https://www.clarity.ms"
  end
end
