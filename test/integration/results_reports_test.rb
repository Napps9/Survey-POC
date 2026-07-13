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
    yielder = ->(survey:, aggregated:, total:, brief: {}, &blk) { blk&.call(MD); MD }
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
    # The 3-question brief and the in-place markdown editor ship in the modal.
    assert_select "[data-report-export-target='brief']"
    assert_select "select[data-report-export-target='length']"
    assert_select "textarea[data-report-export-target='editor']"
  end

  test "generate passes the creator's brief to the generator and persists it" do
    captured = nil
    grabber  = ->(survey:, aggregated:, total:, brief: {}, &blk) { captured = brief; blk&.call(MD); MD }
    stub_method(ResultsReportGenerator, :call, grabber) do
      get survey_results_report_stream_path(@survey,
            regenerate: "1", goal: "Show funder impact", audience: "Board", length: "short")
    end
    assert_response :success
    assert_equal({ "goal" => "Show funder impact", "audience" => "Board", "length" => "short" }, captured)
    assert_equal "short", @survey.reload.results_report_brief_data["length"]
  end

  test "generate forces a regeneration even when the cache is fresh" do
    @survey.update!(results_report: "## Cached\n\nStale take.", results_report_response_count: 1)
    yielder = ->(survey:, aggregated:, total:, brief: {}, &blk) { blk&.call(MD); MD }
    stub_method(ResultsReportGenerator, :call, yielder) do
      get survey_results_report_stream_path(@survey, regenerate: "1", length: "standard")
    end
    assert_response :success
    assert_match "Executive summary", response.body
    assert_equal MD, @survey.reload.results_report, "explicit Generate must replace the cached report"
    assert_nil @survey.results_report_edited_at
  end

  test "a count-triggered regeneration reuses the saved brief" do
    @survey.update!(results_report: "## Old", results_report_response_count: 99, # stale count
                    results_report_brief: { goal: "G", audience: "A", length: "detailed" }.to_json)
    captured = nil
    grabber  = ->(survey:, aggregated:, total:, brief: {}, &blk) { captured = brief; MD }
    stub_method(ResultsReportGenerator, :call, grabber) do
      get survey_results_report_path(@survey, format: :json)
    end
    assert_response :success
    assert_equal "detailed", captured["length"], "regeneration must reuse the persisted brief"
    assert_equal "G", captured["goal"]
  end

  test "saving an edit persists it and syncs the count so it isn't clobbered" do
    # Report generated at count 0; a response has since arrived (count is 1),
    # so without the count sync the next view would regenerate over the edit.
    @survey.update!(results_report: "## AI draft", results_report_response_count: 0)

    patch survey_results_report_path(@survey),
          params: { markdown: "## My edit\n\nHand-tuned." }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_match "My edit", body["body_html"]

    @survey.reload
    assert_equal "## My edit\n\nHand-tuned.", @survey.results_report
    assert_not_nil @survey.results_report_edited_at
    assert_equal 1, @survey.results_report_response_count, "save must sync the count to the current total"

    # The very next view must serve the edit — the generator must NOT run.
    stub_method(ResultsReportGenerator, :call, ->(**) { raise "should not regenerate over an edit" }) do
      get survey_results_report_path(@survey, format: :json)
    end
    assert_response :success
    assert_match "My edit", JSON.parse(response.body)["body_html"]
  end

  test "saving a blank edit is rejected" do
    @survey.update!(results_report: "## Keep me", results_report_response_count: 1)
    patch survey_results_report_path(@survey), params: { markdown: "   " }, as: :json
    assert_response :unprocessable_entity
    assert_equal "## Keep me", @survey.reload.results_report
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
