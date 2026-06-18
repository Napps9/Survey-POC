require "test_helper"

class ResultsReportsTest < ActionDispatch::IntegrationTest
  MD = "## Executive summary\n\nMost respondents picked Blue.\n\n## Key findings\n\n- Blue led (100%)\n".freeze

  def setup
    @user = User.create!(name: "U", email_address: "rr-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "rr-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ])
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: { "0" => { "type" => "multiple_choice", "value" => "Blue" } })
    sign_in(@user)
  end

  test "json returns the rendered report body and caches the markdown" do
    stub_method(ResultsReportGenerator, :call, MD) do
      get survey_results_report_path(@survey, format: :json)
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_match "Executive summary", body["body_html"]
    assert_match "<h2", body["body_html"]
    assert_equal MD, @survey.reload.results_report
    assert_equal 1, @survey.results_report_response_count
  end

  test "pdf streams a real downloadable PDF" do
    stub_method(ResultsReportGenerator, :call, MD) do
      get survey_results_report_path(@survey, format: :pdf)
    end
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_match(/attachment/, response.headers["Content-Disposition"])
    assert_equal "%PDF", response.body[0, 4]
  end

  test "uses the cache without regenerating when fresh" do
    @survey.update!(results_report: "## Cached\n\nReused.", results_report_response_count: 1)
    # If the cache check fails it would call the generator — which raises here.
    stub_method(ResultsReportGenerator, :call, ->(*) { raise "should not regenerate" }) do
      get survey_results_report_path(@survey, format: :json)
    end
    assert_response :success
    assert_match "Cached", JSON.parse(response.body)["body_html"]
  end

  test "stream generates, streams the markdown, and caches it" do
    yielder = ->(survey:, aggregated:, total:, &blk) { blk&.call(MD); MD }
    stub_method(ResultsReportGenerator, :call, yielder) do
      get survey_results_report_stream_path(@survey)
    end
    assert_response :success
    assert_match "Executive summary", response.body
    assert_equal MD, @survey.reload.results_report
  end

  test "stream replays the cached report without regenerating" do
    @survey.update!(results_report: "## Cached\n\nReused.", results_report_response_count: 1)
    stub_method(ResultsReportGenerator, :call, ->(**) { raise "should not regenerate" }) do
      get survey_results_report_stream_path(@survey)
    end
    assert_response :success
    assert_match "Cached", response.body
  end

  test "results page shows the AI Report button" do
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    get survey_results_path(@survey)
    assert_response :success
    assert_select "[data-controller='report-export']"
    assert_select "button[data-action='click->report-export#open']"
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
