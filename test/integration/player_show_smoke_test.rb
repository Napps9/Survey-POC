require "test_helper"

class PlayerShowSmokeTest < ActionDispatch::IntegrationTest
  # The player is public — no session needed. It resolves the Verto by the
  # publish token (PlayerController#load_survey_and_share).
  def published_survey
    org = Organisation.create!(name: "Acme", slug: "acme-#{SecureRandom.hex(2)}")
    survey = org.surveys.create!(
      title: "Sports", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "hi" },
        { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[a b c] }
      ]
    )
    survey.update!(publish_token: SecureRandom.hex(8))
    survey
  end

  test "player renders the client logo centered at the top, with no title bar" do
    survey = published_survey

    get play_survey_path(survey.publish_token)
    assert_response :success

    # The publishing org's logo sits in a slim, centered brand bar at the top —
    # the old top nav (.preview-nav) is gone, so the card keeps the screen.
    assert_select ".player-brandbar img", 1
    assert_select ".preview-nav", false

    # The cards feed and the thank-you screen still render.
    assert_select ".preview-card[data-card-type='welcome_card']"
    assert_select "[data-player-target='thankyou'] .preview-thankyou-card"
  end
end
