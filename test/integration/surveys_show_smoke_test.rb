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
    # Draft share guidance: publishing yields a public link, no respondent account needed.
    assert_match "no Play Verto account needed", response.body
  end

  test "surveys#show on a published Verto states respondents need no account" do
    user = User.create!(name: "U", email_address: "u4-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o4-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    s = org.surveys.create!(title: "Live", theme: "Smoke", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], cards: [ { "type"=>"welcome_card", "title"=>"hi" } ],
      publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get survey_path(s)
    assert_response :success
    assert_match "no Play Verto account or sign-in required", response.body
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
    # The overall Verto score now lives as a tab in the right-hand panel; the
    # tab carries the live score, and clicking it opens the breakdown board.
    assert_select ".right-tabs .verto-score[data-survey-editor-target='vertoScore']"
    assert_match "Verto score", response.body
    # The score-breakdown panel (filled in client-side) and its empty board.
    assert_select ".type-panel[data-publish-panel-target='scoreView'] .score-board[data-survey-editor-target='scoreBoard']"
    # The question card carries a traffic light + an analysis container.
    assert_select "[data-role='card-light']", 1
    assert_select "[data-role='card-analysis']", 1
    # The welcome card is not a question, so it gets no traffic light.
    assert_select ".survey-card-wrap[data-card-type='welcome_card'] [data-role='card-light']", false
  end

  test "the Design panel shows one Branding card with colours, background and logo" do
    user = User.create!(name: "U", email_address: "u5-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    org  = Organisation.create!(name: "O", slug: "o5-#{SecureRandom.hex(2)}")
    org.memberships.create!(user: user, role: "admin")
    s = org.surveys.create!(title: "Smoke", theme: "Smoke", audience_age: "all", key_insight: "x", default_locale: "en", locales: [ "en" ], cards: [])

    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    get survey_path(s)
    assert_response :success
    # One consolidated card, not separate "Brand colours" / "Logo" blocks.
    assert_equal 1, response.body.scan(%r{<div class="publish-block-title">Branding</div>}).size
    refute_match %r{<div class="publish-block-title">Brand colours</div>}, response.body
    refute_match %r{<div class="publish-block-title">Logo</div>}, response.body
    # All three sub-sections live inside it.
    assert_match ">Brand colours</div>", response.body
    assert_match ">Background image</div>", response.body
    assert_match ">Logo</div>", response.body
    assert_match "Upload logo", response.body
  end
end
