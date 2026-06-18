require "test_helper"

# Guards the nonce-based CSP: no page may carry inline on*= event handlers
# (they'd be blocked once script-src drops 'unsafe-inline'). They were all
# refactored to Stimulus controllers / CSS — this keeps them gone.
class InlineHandlersTest < ActionDispatch::IntegrationTest
  HANDLER = /\son(click|change|mouseover|mouseout|mouseenter|mouseleave|focus|blur|input|submit|load|keydown|keyup|keypress)=["']/i

  setup do
    @admin = User.create!(name: "Admin", email_address: "csp-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org = Organisation.create!(name: "CSP Co", slug: "csp-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @admin, role: "admin")
    @survey = @org.surveys.create!(
      title: "S", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "welcome_card", "title" => "hi" },
               { "type" => "multiple_choice", "text" => "Q", "options" => %w[a b] } ],
      publish_token: SecureRandom.hex(8), published_at: Time.current
    )
    sign_in @admin
  end

  def assert_no_inline_handlers(path)
    get path
    assert_response :success
    refute_match HANDLER, response.body, "inline on*= handler rendered on #{path}"
  end

  test "dashboard" do assert_no_inline_handlers root_path end
  test "survey editor" do assert_no_inline_handlers survey_path(@survey) end
  test "results" do assert_no_inline_handlers survey_results_path(@survey) end
  test "new survey wizard" do assert_no_inline_handlers new_survey_path end
  test "common-question-set wizard" do assert_no_inline_handlers new_common_question_set_path end
  test "members" do assert_no_inline_handlers organisation_memberships_path(@org) end
  test "alliances index" do assert_no_inline_handlers alliances_path end

  test "alliance creator view" do
    alliance = @org.alliances.create!(name: "Pilot")
    assert_no_inline_handlers alliance_path(alliance)
  end

  test "public player" do
    get play_survey_path(@survey.publish_token)
    assert_response :success
    refute_match HANDLER, response.body
  end

  private

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end
end
