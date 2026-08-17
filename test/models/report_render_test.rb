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

  # ── kind: report vs infographic ─────────────────────────────────────────

  test "kind defaults to the full report — existing callers that never set it are unaffected" do
    survey = build_survey
    render = survey.report_renders.create!(user: nil)
    assert_equal "report", render.kind
    refute render.infographic?
  end

  test "infographic? is true only for that kind" do
    survey = build_survey
    render = survey.report_renders.create!(user: nil, kind: "infographic")
    assert render.infographic?
  end

  test "an unrecognised kind fails model validation" do
    survey = build_survey
    render = survey.report_renders.build(user: nil, kind: "poster")
    refute render.valid?
    assert_includes render.errors[:kind].join, "included"
  end

  # Matches the pattern already used for status (see enum_constraints_test.rb)
  # and ImageReviewRequest's own kind: a console session or bulk update goes
  # around the model, so the database CHECK is the actual backstop.
  test "kind is constrained in the database, not just the model" do
    survey = build_survey
    render = survey.report_renders.create!(user: nil)
    assert_raises(ActiveRecord::StatementInvalid) do
      render.update_columns(kind: "poster")
    end
  end
end
