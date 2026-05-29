require "test_helper"

class ResultsExportsTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "ex-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ex-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      publish_token: SecureRandom.hex(8), published_at: Time.current,
      cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ]
    )
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en",
                              answers: { "0" => { "type" => "multiple_choice", "value" => "Blue" } })
    sign_in(@user)
  end

  test "downloads the raw-responses CSV as an attachment" do
    get survey_results_export_path(@survey, kind: "responses")
    assert_response :success
    assert_match %r{text/csv}, response.media_type
    assert_match "attachment", response.headers["Content-Disposition"]
    assert_match "verto-#{@survey.id}-responses", response.headers["Content-Disposition"]
    assert_equal [ 0xEF, 0xBB, 0xBF ], response.body.bytes.first(3), "expected a UTF-8 BOM"
    assert_match "Response ID", response.body
    assert_match "Colour?", response.body
    assert_match "Blue", response.body
  end

  test "downloads the aggregated summary CSV" do
    get survey_results_export_path(@survey, kind: "summary")
    assert_response :success
    assert_match "verto-#{@survey.id}-summary", response.headers["Content-Disposition"]
    assert_match "Answer option", response.body
    assert_match "Blue", response.body
  end

  test "cannot export another org's Verto" do
    other = User.create!(name: "Z", email_address: "z-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org2  = Organisation.create!(name: "O2", slug: "ex2-#{SecureRandom.hex(3)}")
    org2.memberships.create!(user: other, role: "admin")
    sign_in(other)

    get survey_results_export_path(@survey, kind: "responses")
    assert_response :not_found
  end

  test "results page shows the Download CSV control and hides Google when unconfigured" do
    get survey_results_path(@survey)
    assert_response :success
    assert_match "Download CSV", response.body
    assert_no_match(/Connect Google Sheets|Export to Google Sheets/, response.body)
  end

  test "results page shows Connect when configured but not connected, Export once connected" do
    prev = ENV.values_at("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    ENV["GOOGLE_CLIENT_ID"]     = "id.apps.googleusercontent.com"
    ENV["GOOGLE_CLIENT_SECRET"] = "secret"

    get survey_results_path(@survey)
    assert_response :success
    assert_match "Connect Google Sheets", response.body

    @user.update!(google_refresh_token: "rt")
    get survey_results_path(@survey)
    assert_response :success
    assert_match "Export to Google Sheets", response.body
    assert_match survey_google_sheet_path(@survey, segment: "overall"), response.body
  ensure
    ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] = prev
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
