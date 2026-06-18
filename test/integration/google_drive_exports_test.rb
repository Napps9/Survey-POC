require "test_helper"

class GoogleDriveExportsTest < ActionDispatch::IntegrationTest
  def setup
    @prev = ENV.values_at("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    ENV["GOOGLE_CLIENT_ID"]     = "test-client-id.apps.googleusercontent.com"
    ENV["GOOGLE_CLIENT_SECRET"] = "test-secret"

    @user = User.create!(name: "U", email_address: "gd-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "gd-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ])
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed",
                              answers: { "0" => { "type" => "multiple_choice", "value" => "Blue" } })
    # Pre-cache the report so the controller doesn't reach for Claude.
    @survey.update!(results_report: "## Report\n\nBlue led.", results_report_response_count: 1)
    sign_in(@user)
  end

  def teardown
    ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] = @prev
  end

  test "creates a Google Doc and returns its url when connected" do
    @user.update!(google_refresh_token: "refresh-xyz")
    result = GoogleDriveWriter::Result.new(url: "https://docs.google.com/document/d/abc", id: "abc")

    stub_method(GoogleDriveWriter, :call, result) do
      post survey_google_drive_path(@survey)
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "https://docs.google.com/document/d/abc", body["url"]
  end

  test "asks the user to connect when not yet connected" do
    post survey_google_drive_path(@survey)
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["reconnect"]
    assert_match "/google/connect", body["connect_url"]
  end

  test "clears the token and asks to reconnect when it has been revoked" do
    @user.update!(google_refresh_token: "revoked")

    stub_method(GoogleDriveWriter, :call, ->(*) { raise GoogleOauthService::NotConnected }) do
      post survey_google_drive_path(@survey)
    end

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["reconnect"]
    refute @user.reload.google_connected?, "revoked token should be cleared"
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
