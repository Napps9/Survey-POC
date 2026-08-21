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

  # ── Direction prompt (one shuffle, never stored) ─────────────────────────

  def draft
    @org.surveys.create!(
      title: "S", theme: "Football fans", audience_age: "18-24", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [ { "type" => "multiple_choice", "text" => "Favourite team?", "options" => %w[A B] } ]
    )
  end

  test "the direction steers the shuffle it was submitted with" do
    s = draft
    post shuffle_survey_assets_path(s), params: { direction: "no sport" }
    assert_response :redirect

    refute_includes s.reload.background_image, "backgrounds/sport-",
      "the veto submitted with the click applies to that same shuffle"
  end

  test "a direction is never stored, so the next shuffle starts clean" do
    s = draft
    post shuffle_survey_assets_path(s), params: { direction: "no sport" }
    steered = s.reload.background_image

    # Nothing was kept, so an undirected shuffle is free to land back on the
    # sport backdrop the veto had ruled out. Same seed space, no memory.
    20.times do
      post shuffle_survey_assets_path(s)
      break if s.reload.background_image.include?("backgrounds/sport-")
    end
    assert_includes s.reload.background_image, "backgrounds/sport-",
      "a steer typed once must not go on deciding shuffles it wasn't typed for"
    assert_not_equal steered, s.background_image
  end

  test "the editor's direction box always starts empty" do
    s = draft
    # Deliberately not wording from the placeholder, which would match anyway.
    post shuffle_survey_assets_path(s), params: { direction: "harbour cranes" }
    follow_redirect!

    get survey_path(s)
    assert_response :success
    assert_match 'name="direction"', response.body, "the prompt still posts with the shuffle form"
    assert_match %r{<textarea[^>]*id="shuffle-direction"[^>]*></textarea>}, response.body,
      "and comes back empty rather than pre-filled with the last steer"
    refute_match "harbour", response.body
  end

  test "the shuffle reports back what the direction was read as, once" do
    s = draft
    post shuffle_survey_assets_path(s), params: { direction: "warm natural light, no offices" }
    follow_redirect!

    assert_match "Last shuffle searched for: warm, natural, light", response.body,
      "a misparse has to be visible here, not only in the pictures"
    assert_match "kept out: offices", response.body

    # Flash, not state: gone on the next view of the same page.
    get survey_path(s)
    refute_match "Last shuffle searched for", response.body
  end

  test "a live Verto ignores the direction along with the shuffle" do
    s = draft
    s.update!(publish_token: SecureRandom.urlsafe_base64(18), published_at: Time.current)
    before = s.reload.cards

    post shuffle_survey_assets_path(s), params: { direction: "no sport" }
    assert_redirected_to survey_path(s)
    assert_equal before, s.reload.cards, "a locked Verto's imagery is untouched"
  end

  test "an over-long direction is capped before it reaches the search" do
    s = draft
    long = "seaside " * 200
    terms = AssetPopulator.direction_reading(s, long)[:toward]

    assert_equal Survey::MAX_SHUFFLE_DIRECTION,
                 Survey.sanitize_shuffle_direction(long).length
    assert_equal %w[seaside], terms, "and still parses to something sane"
  end

  test "Survey.sanitize_shuffle_direction collapses, caps and blanks to nil" do
    assert_equal "warm outdoors", Survey.sanitize_shuffle_direction("  warm\n\t outdoors  ")
    assert_nil   Survey.sanitize_shuffle_direction("   ")
    assert_nil   Survey.sanitize_shuffle_direction(nil)
    assert_equal Survey::MAX_SHUFFLE_DIRECTION,
                 Survey.sanitize_shuffle_direction("a" * 500).length
  end
end
