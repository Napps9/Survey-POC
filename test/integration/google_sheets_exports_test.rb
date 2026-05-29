require "test_helper"

class GoogleSheetsExportsTest < ActionDispatch::IntegrationTest
  def setup
    @prev = ENV.values_at("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    ENV["GOOGLE_CLIENT_ID"]     = "test-client-id.apps.googleusercontent.com"
    ENV["GOOGLE_CLIENT_SECRET"] = "test-secret"

    @user = User.create!(name: "U", email_address: "gs-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "gs-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "multiple_choice", "text" => "Colour?", "options" => %w[Blue Green] } ])
    @survey.responses.create!(session_token: SecureRandom.uuid, status: "completed", locale: "en",
                              answers: { "0" => { "type" => "multiple_choice", "value" => "Blue" } })
    sign_in(@user)
  end

  def teardown
    ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] = @prev
  end

  test "creates a sheet and returns its url when connected" do
    @user.update!(google_refresh_token: "refresh-xyz")
    result = GoogleSheetsWriter::Result.new(url: "https://docs.google.com/spreadsheets/d/abc", id: "abc")

    stub_method(GoogleSheetsWriter, :call, result) do
      post survey_google_sheet_path(@survey, segment: "overall")
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_equal "https://docs.google.com/spreadsheets/d/abc", body["url"]
  end

  test "asks the user to connect when not yet connected" do
    post survey_google_sheet_path(@survey)
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["reconnect"]
    assert_match "/google/connect", body["connect_url"]
  end

  test "clears the token and asks to reconnect when it has been revoked" do
    @user.update!(google_refresh_token: "revoked")

    stub_method(GoogleSheetsWriter, :call, ->(*) { raise GoogleOauthService::NotConnected }) do
      post survey_google_sheet_path(@survey)
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["reconnect"]
    refute @user.reload.google_connected?, "revoked token should be cleared"
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
