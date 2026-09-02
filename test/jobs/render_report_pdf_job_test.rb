require "test_helper"

# The render jobs run inside the Puma process (Solid Queue :async), so a
# deploy or a memory-watchdog restart kills them mid-render. Solid Queue
# releases the claimed job for re-delivery, and the re-delivered job finds the
# row already "running" — that must mean "redo", never "skip", or the row sits
# there until stale? fails it five minutes later.
class RenderReportPdfJobTest < ActiveJob::TestCase
  def setup
    @org    = Organisation.create!(name: "O", slug: "rj-#{SecureRandom.hex(3)}")
    @user   = User.create!(name: "U", email_address: "rj-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @survey = @org.surveys.create!(title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ])
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: { "0" => { "type" => "multiple_choice", "value" => "Blue" } })
    @survey.update!(results_report: "## Report\n\nBlue led.", results_report_response_count: 1)
  end

  test "a re-delivered job redoes a render whose first attempt died mid-run" do
    render = @survey.report_renders.create!(user: @user, kind: "report")
    render.start! # the first attempt got this far, then its process was restarted

    RenderReportPdfJob.perform_now(render.id)

    render.reload
    assert render.succeeded?, "expected the interrupted render to be redone, got #{render.status}"
    assert render.document.attached?
    assert_equal "%PDF", render.document.download[0, 4]
  end

  test "the share card is redone the same way" do
    render = @survey.report_renders.create!(user: @user, kind: "infographic")
    render.start!

    RenderInfographicJob.perform_now(render.id)

    assert render.reload.succeeded?
  end

  test "a finished render is left alone" do
    render = @survey.report_renders.create!(user: @user, kind: "report")
    render.fail!("earlier")

    RenderReportPdfJob.perform_now(render.id)

    assert render.reload.failed?
    assert_equal "earlier", render.error_message
  end
end
