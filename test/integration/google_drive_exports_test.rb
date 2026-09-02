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

  # A 4xx from Drive is something a person has to act on — an API left
  # disabled in the Cloud project most of all, since the Sheets export needs
  # only the Sheets API and works fine without Drive's. "Try again" would
  # just produce the same 403, so the response says what to fix.
  test "says the Drive API is disabled rather than 'try again' when Google reports that" do
    @user.update!(google_refresh_token: "refresh-xyz")
    error = Google::Apis::ClientError.new(
      "accessNotConfigured: Google Drive API has not been used in project 1234 before or it is disabled.",
      status_code: 403
    )

    stub_method(GoogleDriveWriter, :call, ->(*) { raise error }) do
      post survey_google_drive_path(@survey)
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    refute body["reconnect"], "a disabled API isn't fixed by reconnecting"
    assert_match "Google Drive API", body["error"]
    assert_match "Google Cloud", body["error"]
    assert @user.reload.google_connected?, "the token is still good; don't throw it away"
  end

  test "passes the reason through for any other Drive rejection" do
    @user.update!(google_refresh_token: "refresh-xyz")
    error = Google::Apis::ClientError.new("storageQuotaExceeded: The user's Drive storage quota has been exceeded.",
                                          status_code: 403)

    stub_method(GoogleDriveWriter, :call, ->(*) { raise error }) do
      post survey_google_drive_path(@survey)
    end

    assert_response :unprocessable_entity
    assert_match "storage quota has been exceeded", JSON.parse(response.body)["error"]
  end

  test "sends the user back through consent when the token lacks the Drive scope" do
    @user.update!(google_refresh_token: "narrow-scope")
    error = Google::Apis::ClientError.new(
      "insufficientPermissions: Request had insufficient authentication scopes.", status_code: 403
    )

    stub_method(GoogleDriveWriter, :call, ->(*) { raise error }) do
      post survey_google_drive_path(@survey)
    end

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["reconnect"]
    refute @user.reload.google_connected?, "a token without the scope must be replaced, not retried"
  end

  test "sends the user back through consent when Drive rejects the access token" do
    @user.update!(google_refresh_token: "revoked-since")

    stub_method(GoogleDriveWriter, :call, ->(*) { raise Google::Apis::AuthorizationError.new("Unauthorized", status_code: 401) }) do
      post survey_google_drive_path(@survey)
    end

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["reconnect"]
    refute @user.reload.google_connected?
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
