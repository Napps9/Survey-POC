require "test_helper"

class ReportRenderTest < ActiveSupport::TestCase
  def build_survey
    org = Organisation.create!(name: "RR Org", slug: "rrm-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "S", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: [])
  end

  # shared_request? is RenderReportPdfJob's ONLY signal for "never regenerate,
  # never spend AI" — see the job's own comment.
  test "a render with no user is a shared request" do
    survey = build_survey
    render = survey.report_renders.create!(user: nil)
    assert render.shared_request?
  end

  test "a render with a signed-in user is not a shared request" do
    survey = build_survey
    user   = User.create!(name: "U", email_address: "rrm-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    render = survey.report_renders.create!(user: user)
    refute render.shared_request?
  end
end
