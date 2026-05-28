require "test_helper"

class SurveysShuffleAssetsTest < ActionDispatch::IntegrationTest
  def setup
    AssetPopulator.reset_manifest_cache!
    @user = User.create!(name: "U", email_address: "u-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "sh-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  test "shuffle_assets replaces background and card images" do
    s = @org.surveys.create!(
      title: "S", theme: "Football fans", audience_age: "18-24", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "multiple_choice", "text" => "Favourite team?", "options" => %w[Arsenal Chelsea Spurs] },
        { "type" => "tap_card",        "text" => "Swipe",           "options" => %w[a b c] }
      ]
    )

    post shuffle_survey_assets_path(s)
    assert_response :redirect
    follow_redirect!
    assert_response :success

    s.reload
    assert s.background_image.present?, "shuffle should set a background"
    s.cards.each_with_index do |c, i|
      if c["type"] == "tap_card"
        assert Array(c["option_images"]).any?, "tap_card #{i} should have option_images"
      else
        assert c["image"].present?, "card #{i} (#{c['type']}) should have an image"
      end
    end
  end

  test "editor renders a Shuffle button" do
    s = @org.surveys.create!(
      title: "S", theme: "Sport", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: []
    )
    get survey_path(s)
    assert_response :success
    assert_match ">Shuffle<", response.body
  end
end
