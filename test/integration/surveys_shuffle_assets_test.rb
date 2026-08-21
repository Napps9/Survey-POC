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

  # ── Direction prompt ─────────────────────────────────────────────────────

  def draft(direction: nil)
    @org.surveys.create!(
      title: "S", theme: "Football fans", audience_age: "18-24", key_insight: "k",
      default_locale: "en", locales: [ "en" ], shuffle_direction: direction,
      cards: [ { "type" => "multiple_choice", "text" => "Favourite team?", "options" => %w[A B] } ]
    )
  end

  test "shuffle_assets stores the direction, keeps it, and clears it on an empty submit" do
    s = draft

    post shuffle_survey_assets_path(s), params: { direction: "  warm  natural light,\n no offices " }
    assert_response :redirect
    assert_equal "warm natural light, no offices", s.reload.shuffle_direction,
      "whitespace is collapsed, the words are left alone"

    # A shuffle that doesn't send the field at all leaves the stored steer be.
    post shuffle_survey_assets_path(s)
    assert_equal "warm natural light, no offices", s.reload.shuffle_direction

    # Submitting the box empty is how a creator clears it.
    post shuffle_survey_assets_path(s), params: { direction: "" }
    assert_nil s.reload.shuffle_direction
  end

  test "a stored direction is length-capped" do
    s = draft
    post shuffle_survey_assets_path(s), params: { direction: "seaside " * 200 }
    assert_equal Survey::MAX_SHUFFLE_DIRECTION, s.reload.shuffle_direction.length
  end

  test "a live Verto's direction can't be changed by a shuffle post" do
    s = draft(direction: "warm, outdoors")
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)

    post shuffle_survey_assets_path(s), params: { direction: "cold, indoors" }
    assert_redirected_to survey_path(s)
    assert_equal "warm, outdoors", s.reload.shuffle_direction
  end

  test "the direction actually steers the shuffle it was submitted with" do
    s = draft
    post shuffle_survey_assets_path(s), params: { direction: "no sport" }
    assert_response :redirect

    s.reload
    assert_equal "no sport", s.shuffle_direction
    refute_includes s.background_image, "backgrounds/sport-",
      "the veto submitted with the click applies to that same shuffle"
  end

  test "the editor renders the direction prompt beside Shuffle, pre-filled" do
    s = draft(direction: "warm natural light, no offices")
    get survey_path(s)
    assert_response :success

    assert_match 'name="direction"', response.body, "the prompt posts with the shuffle form"
    assert_match "warm natural light, no offices", response.body, "and is pre-filled with the stored steer"
    assert_match "shuffle-pill-caret is-set", response.body, "the pill shows a direction is set"
    assert_match 'data-controller="shuffle"', response.body
  end

  test "the direction prompt is empty and unmarked on a Verto that has none" do
    get survey_path(draft)
    assert_response :success

    assert_match 'name="direction"', response.body
    refute_match "shuffle-pill-caret is-set", response.body
  end

  test "Survey.sanitize_shuffle_direction collapses, caps and blanks to nil" do
    assert_equal "warm outdoors", Survey.sanitize_shuffle_direction("  warm\n\t outdoors  ")
    assert_nil   Survey.sanitize_shuffle_direction("   ")
    assert_nil   Survey.sanitize_shuffle_direction(nil)
    assert_equal Survey::MAX_SHUFFLE_DIRECTION,
                 Survey.sanitize_shuffle_direction("a" * 500).length
  end

  test "the panel shows what the direction was actually read as" do
    s = draft(direction: "warm natural light, no offices")
    get survey_path(s)
    assert_response :success

    assert_match "Searching for: warm, natural", response.body,
      "the creator can see which words reach the search"
    assert_match "Keeping out: offices", response.body

    # Nothing to report on a Verto with no direction.
    refute_match "Searching for:", body_for(draft)
  end

  def body_for(survey)
    get survey_path(survey)
    response.body
  end
end
