require "test_helper"

# The two halves of the cold-cache fix for "having to refresh the page to be
# able to select an answer": the first card ships .active from the server (no
# blank screen while JS boots), and the player's interactive modules carry
# modulepreload hints so the lazy-load waterfall collapses to one fetch wave.
class PlayerFirstPaintTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "text" => "hi" },
    { "type" => "multiple_choice", "text" => "Q1", "options" => [ "A", "B" ] },
    { "type" => "yes_no", "text" => "Q2", "options" => [ "Yes", "No" ] }
  ].freeze

  def live_survey(respondent_code: false)
    org = Organisation.create!(name: "O", slug: "fp-#{SecureRandom.hex(3)}")
    org.surveys.create!(
      title: "T", theme: "T", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: CARDS,
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current,
      respondent_code_enabled: respondent_code
    )
  end

  test "exactly the first card is server-rendered active" do
    get play_survey_path(live_survey.publish_token)
    assert_response :success
    assert_select "div.preview-card.active", count: 1
    # ...and it is the FIRST card target, so what paints is what the player
    # controller will re-activate at boot (currentValue defaults to 0).
    first = css_select("div.preview-card").first
    assert_includes first["class"].split, "active"
  end

  test "with a respondent-code gate, the gate is the active first paint" do
    get play_survey_path(live_survey(respondent_code: true).publish_token)
    assert_response :success
    assert_select "div.preview-card.active", count: 1
    assert_equal "respondent_code_card", css_select("div.preview-card.active").first["data-card-type"]
  end

  test "the player preloads its interactive modules" do
    get play_survey_path(live_survey.publish_token)
    assert_select "link[rel=modulepreload][href*='/player_controller']", 1
    assert_select "link[rel=modulepreload][href*='picker_controller']", 1
    assert_select "link[rel=modulepreload][href*='controllers/index']", 1
    # lottie-web stays lazy — 300KB the average deck never runs.
    assert_select "link[rel=modulepreload][href*='lottie-web']", 0
  end

  test "the studio does not inherit the player's preloads" do
    user = User.create!(name: "U", email_address: "fp-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "fp-s-#{SecureRandom.hex(3)}")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }

    get root_path
    assert_response :success
    assert_select "link[rel=modulepreload][href*='player_controller']", 0
  end
end
