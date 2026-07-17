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

  test "shuffle_assets sets a range card's reaction animation" do
    s = @org.surveys.create!(
      title: "S", theme: "Climate action", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "range", "text" => "How worried are you?", "options" => %w[Low Med High] } ]
    )

    post shuffle_survey_assets_path(s)
    assert_response :redirect

    theme = s.reload.cards[0]["range_theme"]
    assert_includes NpsHelper::RANGE_THEMES, theme, "shuffle should set a known range animation"
    pool = NpsHelper.range_themes_for("Climate action")
    assert_includes pool, theme, "shuffle should pick a theme-matched animation"
    refute_includes pool, "basketball", "no off-theme sport animation for a climate Verto"
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

  test "editor renders the Change-animation CTA and picker for a range card" do
    s = @org.surveys.create!(
      title: "S", theme: "Climate", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "range", "text" => "How worried?", "options" => %w[Low High], "range_theme" => "recycling" } ]
    )
    get survey_path(s)
    assert_response :success
    # The per-card CTA on the animation panel…
    assert_match "add-animation-fab", response.body
    assert_match "animation-picker#open", response.body
    # …and the picker modal it opens, wired to the same controller.
    assert_match 'data-controller="type-panel preview-verto survey-editor media-picker animation-picker', response.body
    assert_match "animation-picker#pick", response.body
    # Every animation set is offered as an option.
    NpsHelper::RANGE_THEMES.each do |slug|
      assert_match "data-slug=\"#{slug}\"", response.body, "picker should offer the #{slug} animation"
    end
  end
end
