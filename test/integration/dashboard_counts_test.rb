require "test_helper"

# The dashboard derives per-survey responder/completion/response counts from
# grouped SQL queries (SurveysController#index) rather than loading every
# response's answers JSON. This guards that wiring end-to-end.
class DashboardCountsTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "dash-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "dash-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(title: "Live", theme: "DashTheme", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" }, { "type" => "yes_no", "text" => "Q", "options" => %w[Yes No] } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
  end

  def add_response(value:, status:)
    @survey.responses.create!(session_token: SecureRandom.uuid, status: status,
      answers: value.nil? ? {} : { "1" => { "value" => value } })
  end

  test "dashboard shows responder count and completion derived from grouped counts" do
    add_response(value: "Yes", status: "completed")
    add_response(value: "No",  status: "completed")
    add_response(value: "Yes", status: "started")  # responder, not completed
    add_response(value: nil,   status: "started")  # not a responder

    get root_path
    assert_response :success
    assert_match "DashTheme", response.body
    # The summary strip is responder-based, matching the Verto cards: 3 responders
    # (the empty "started" row is not a responder), 2 completed → 67% (not the
    # old opens-based 2/4 = 50%), and the tile is now labelled "Responders".
    assert_match "67%", response.body
    assert_match I18n.t("dashboard.stat_responders"), response.body
  end

  test "dashboard renders with no responses" do
    get root_path
    assert_response :success
    assert_match "DashTheme", response.body
  end
end
