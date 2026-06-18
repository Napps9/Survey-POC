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

  test "no top nav bar, and no welcome logo when none is uploaded" do
    survey = published_survey

    get play_survey_path(survey.publish_token)
    assert_response :success

    assert_select ".preview-nav", false
    # No logo uploaded → nothing shown (never the Playverto fallback here).
    assert_select ".split-left-logo", false

    # The cards feed and the thank-you screen still render.
    assert_select ".preview-card[data-card-type='welcome_card']"
    assert_select "[data-player-target='thankyou'] .preview-thankyou-card"
  end

  test "welcome card shows the creator's logo, centred, when one is uploaded" do
    survey = published_survey
    survey.organisation.logo.attach(
      io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: "logo.png", content_type: "image/png"
    )

    get play_survey_path(survey.publish_token)
    assert_response :success
    assert_select ".split-left .split-left-logo img", 1
  end
end
