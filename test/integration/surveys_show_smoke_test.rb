require "test_helper"

class SurveysShowSmokeTest < ActionDispatch::IntegrationTest
  test "surveys#show renders for a creator org without alliances or shares" do
    user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    s = org.surveys.create!(title: "Smoke", theme: "Smoke", audience_age: "all", key_insight: "x", default_locale: "en", locales: [ "en" ], cards: [ { "type"=>"welcome_card", "title"=>"hi" } ])

    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get survey_path(s)
    assert_response :success
    assert_match "Share with an alliance", response.body
    assert_match "Create an alliance →", response.body, "empty-alliances state should prompt to create one"
  end

  test "surveys#show 'Add to alliance' block lists available alliances" do
    user = User.create!(name: "U", email_address: "u2-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o2-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    org.alliances.create!(name: "Pilot")
    s = org.surveys.create!(title: "Smoke", theme: "Smoke", audience_age: "all", key_insight: "x", default_locale: "en", locales: [ "en" ], cards: [])

    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get survey_path(s)
    assert_response :success
    assert_match "Pilot", response.body
    assert_match "Add to alliance", response.body
  end

  test "surveys#show renders the Rules-of-the-Game traffic lights" do
    user = User.create!(name: "U", email_address: "u3-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o3-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    s = org.surveys.create!(
      title: "Smoke", theme: "Smoke", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[a b c] }
      ]
    )

    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get survey_path(s)
    assert_response :success
    # Overall Verto score pill in the finalize bar.
    assert_select ".verto-score[data-survey-editor-target='vertoScore']"
    assert_match "Verto score", response.body
    # The question card carries a traffic light + an analysis container.
    assert_select "[data-role='card-light']", 1
    assert_select "[data-role='card-analysis']", 1
    # The welcome card is not a question, so it gets no traffic light.
    assert_select ".survey-card-wrap[data-card-type='welcome_card'] [data-role='card-light']", false
  end
end
