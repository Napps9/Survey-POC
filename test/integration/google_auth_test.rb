require "test_helper"

class GoogleAuthTest < ActionDispatch::IntegrationTest
  def setup
    @prev = ENV.values_at("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    ENV["GOOGLE_CLIENT_ID"]     = "test-client-id.apps.googleusercontent.com"
    ENV["GOOGLE_CLIENT_SECRET"] = "test-secret"

    @user = User.create!(name: "U", email_address: "ga-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ga-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(title: "X", theme: "Demo", audience_age: "all", key_insight: "k",
                                   default_locale: "en", locales: [ "en" ], cards: [])
    sign_in(@user)
  end

  def teardown
    ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"] = @prev
  end

  test "connect redirects to Google's consent screen with a state" do
    get google_connect_path(survey_id: @survey.id, segment: "overall")
    assert_response :redirect
    assert_match %r{\Ahttps://accounts\.google\.com/o/oauth2/auth}, response.location
    assert_match "access_type=offline", response.location
    refute_nil oauth_state_from(response.location)
  end

  test "callback stores tokens and returns to results when state matches" do
    get google_connect_path(survey_id: @survey.id, segment: "overall")
    state = oauth_state_from(response.location)

    tokens = { refresh_token: "refresh-xyz", access_token: "access-xyz", expires_at: 1.hour.from_now }
    stub_method(GoogleOauthService, :exchange_code!, tokens) do
      get google_callback_path, params: { code: "auth-code", state: state }
    end

    assert_redirected_to survey_results_path(@survey.id, segment: "overall", google_connected: 1)
    assert_equal "refresh-xyz", @user.reload.google_refresh_token
    assert @user.google_connected?
  end

  test "callback rejects a mismatched state without storing tokens" do
    get google_connect_path(survey_id: @survey.id, segment: "overall")

    called = false
    stub_method(GoogleOauthService, :exchange_code!, ->(*) { called = true; {} }) do
      get google_callback_path, params: { code: "auth-code", state: "not-the-real-state" }
    end

    assert_redirected_to survey_results_path(@survey.id, segment: "overall", google_error: 1)
    refute called, "should not exchange the code on a state mismatch"
    refute @user.reload.google_connected?
  end

  private

  def oauth_state_from(location)
    Rack::Utils.parse_query(URI(location).query)["state"]
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
