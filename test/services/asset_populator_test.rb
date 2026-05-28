require "test_helper"

class AssetPopulatorTest < ActiveSupport::TestCase
  def setup
    AssetPopulator.reset_manifest_cache!
    @org = Organisation.create!(name: "O", slug: "ap-#{SecureRandom.hex(3)}")
  end

  def make_survey(theme:, audience_age: "all", cards:)
    @org.surveys.create!(
      title: "T", theme: theme, audience_age: audience_age, key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: cards
    )
  end

  test "populate! sets background_image to a /assets/verto-library path" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?" } ])

    AssetPopulator.new(s).populate!

    assert_match %r{\A/assets/verto-library/backgrounds/.+\.jpg\z}i, s.background_image
    assert Survey.sanitize_background_image(s.background_image),
      "background_image must pass Survey.sanitize_background_image"
  end

  test "populate! gives every non-tap_card card an image and every tap_card option_images" do
    cards = [
      { "type" => "welcome_card",    "text" => "Welcome" },
      { "type" => "multiple_choice", "text" => "Pick one", "options" => [ "A", "B" ] },
      { "type" => "range",           "text" => "How hard?", "options" => [ "Easy", "Hard" ] },
      { "type" => "rating",          "text" => "Rate it" },
      { "type" => "nps",             "text" => "Recommend?" },
      { "type" => "tap_card",        "text" => "Swipe", "options" => [ "x", "y", "z" ] },
      { "type" => "open_ended",      "text" => "Thoughts?" }
    ]
    s = make_survey(theme: "Sport fans", audience_age: "18-24", cards: cards)

    AssetPopulator.new(s).populate!

    s.reload
    s.cards.each_with_index do |c, i|
      if c["type"] == "tap_card"
        assert_equal Array(c["options"]).size, Array(c["option_images"]).size,
          "tap_card #{i} option_images count must match options count"
        c["option_images"].each do |u|
          assert_includes u, "verto-library/swipe-cards/"
        end
      else
        assert c["image"].present?, "card #{i} (#{c['type']}) has no image"
      end
    end
  end

  test "sport theme picks sports-people left-panel art for compatible card types" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?",
                               "options" => [ "Arsenal", "Chelsea" ] } ])

    AssetPopulator.new(s).populate!

    s.reload
    assert_includes s.cards[0]["image"], "verto-library/left-panel/sports-people-desktop-",
      "expected Tier-1 themed match, got #{s.cards[0]['image'].inspect}"
  end

  test "non-themed survey falls through to type-art for range / select; tap_card left panel stays blank" do
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [
                      { "type" => "tap_card",        "text" => "Agree?", "options" => %w[a b c] },
                      { "type" => "range",           "text" => "Rate it" },
                      { "type" => "multiple_choice", "text" => "Pick", "options" => %w[a b] }
                    ])

    AssetPopulator.new(s).populate!

    s.reload
    # tap_card left panel intentionally blank — statement imagery does the work
    assert_nil s.cards[0]["image"], "tap_card left panel must NOT pull from swipe-cards/"
    assert_equal 3, Array(s.cards[0]["option_images"]).size
    s.cards[0]["option_images"].each { |u| assert_includes u, "verto-library/swipe-cards/" }
    assert_includes s.cards[1]["image"], "verto-library/range-art/"
    assert_includes s.cards[2]["image"], "verto-library/select-art/"
  end

  test "card with no Tier-1/Tier-2 match gets no image (no SVG fallback)" do
    # open_ended has no type-family bucket, and "Climate action" theme has no
    # themed left-panel art, so the card image must be nil — never an SVG path.
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "Anything to add?" } ])

    AssetPopulator.new(s).populate!

    s.reload
    assert_nil s.cards[0]["image"]
  end

  test "food theme expands through cluster to match nature background" do
    s = make_survey(theme: "healthy sustainable food", audience_age: "18-30",
                    cards: [ { "type" => "open_ended", "text" => "Thoughts?" } ])

    AssetPopulator.new(s).populate!

    s.reload
    assert_match %r{verto-library/backgrounds/nature(?:-[a-f0-9]+)?\.jpg}i, s.background_image,
      "food theme must pull in nature via the theme_clusters expansion, got #{s.background_image.inspect}"
  end

  test "climate theme picks the nature background, not sport, despite age/mood bonuses" do
    s = make_survey(theme: "Climate", audience_age: "15-20",
                    cards: [ { "type" => "open_ended", "text" => "Thoughts?" } ])

    AssetPopulator.new(s).populate!

    s.reload
    assert_match %r{verto-library/backgrounds/nature(?:-[a-f0-9]+)?\.jpg}i, s.background_image,
      "Climate theme must pick nature.jpg over sport.jpg, got #{s.background_image.inspect}"
    refute_match %r{/backgrounds/sport[-.]}i, s.background_image
  end

  test "climate theme skips sports-people Tier-1 art on cards (no thematic connection)" do
    s = make_survey(theme: "Climate", audience_age: "15-20",
                    cards: [ { "type" => "multiple_choice", "text" => "How worried are you?",
                               "options" => %w[Very Somewhat NotAtAll] } ])

    AssetPopulator.new(s).populate!

    s.reload
    img = s.cards[0]["image"].to_s
    refute_includes img, "verto-library/left-panel/sports-people",
      "off-theme sports-people art must not land on a Climate card"
  end

  test "tap_card option_images are unique within a card" do
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [ { "type" => "tap_card", "text" => "Agree?",
                               "options" => %w[a b c d e] } ])

    AssetPopulator.new(s).populate!

    s.reload
    imgs = Array(s.cards[0]["option_images"])
    assert_equal 5, imgs.size
    assert_equal imgs.size, imgs.uniq.size, "option_images must be unique within a card"
  end

  test "same seed produces identical picks" do
    cards = [ { "type" => "tap_card", "text" => "Swipe", "options" => %w[a b c] } ] * 3
    s1 = make_survey(theme: "Sport", audience_age: "18-24", cards: cards.deep_dup)
    s2 = make_survey(theme: "Sport", audience_age: "18-24", cards: cards.deep_dup)

    AssetPopulator.new(s1, seed: "fixed-seed").populate!
    AssetPopulator.new(s2, seed: "fixed-seed").populate!

    assert_equal s1.reload.background_image, s2.reload.background_image
    assert_equal s1.cards.map { |c| c["image"] }, s2.cards.map { |c| c["image"] }
  end

  test "shuffle (different seed) yields a different picture set" do
    cards = (1..6).map { { "type" => "tap_card", "text" => "Swipe", "options" => %w[a b c] } }
    s1 = make_survey(theme: "Sport", audience_age: "18-24", cards: cards.deep_dup)
    s2 = make_survey(theme: "Sport", audience_age: "18-24", cards: cards.deep_dup)

    AssetPopulator.new(s1, seed: "seed-A").populate!
    AssetPopulator.new(s2, seed: "seed-B").populate!

    s1_opts = s1.reload.cards.flat_map { |c| Array(c["option_images"]) }
    s2_opts = s2.reload.cards.flat_map { |c| Array(c["option_images"]) }
    refute_equal s1_opts, s2_opts,
      "two different seeds should usually pick different swipe-card art across 18 statements"
  end

  test "no duplicate left-panel pictures across cards (within Tier 1 pool)" do
    cards = (1..5).map { |i| { "type" => "multiple_choice", "text" => "Q#{i}", "options" => %w[a b] } }
    s = make_survey(theme: "Sport", audience_age: "18-24", cards: cards)

    AssetPopulator.new(s).populate!

    s.reload
    tier1_imgs = s.cards.map { |c| c["image"] }.select { |img| img.include?("/left-panel/") }
    assert_equal tier1_imgs.size, tier1_imgs.uniq.size,
      "Tier-1 picks must be unique: #{tier1_imgs.inspect}"
  end
end
