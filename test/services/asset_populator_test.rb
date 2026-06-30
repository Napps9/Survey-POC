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

  test "populate! gives image-bearing cards an image; tap_card option_images; range stays blank" do
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
      case c["type"]
      when "tap_card"
        assert_equal Array(c["options"]).size, Array(c["option_images"]).size,
          "tap_card #{i} option_images count must match options count"
        c["option_images"].each { |u| assert_includes u, "verto-library/swipe-cards/" }
      when "range"
        # Range shows the reactive Lottie on its left panel — no still image.
        assert_nil c["image"], "range card must not get a left-panel still"
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

  test "non-themed survey: tap_card + range left panels stay blank; select falls through to type-art" do
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
    # range shows the reactive Lottie, so it carries no still image
    assert_nil s.cards[1]["image"]
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

  # ── Question-aware image query ────────────────────────────────────────────

  test "card query keeps the question's subject and drops survey filler" do
    s = make_survey(theme: "Retail", audience_age: "all",
                    cards: [ { "type" => "multiple_choice",
                               "text" => "Which laptop brand would you prefer?",
                               "options" => %w[Apple Dell] } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    assert_includes q, "laptop"
    assert_includes q, "brand"
    %w[which would you prefer].each { |w| refute_includes q, w, "#{w.inspect} is filler" }
  end

  test "card query leads with the question subject, not the survey theme" do
    s = make_survey(theme: "Climate action", audience_age: "all",
                    cards: [ { "type" => "open_ended", "text" => "How was your coffee this morning?" } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0]).split

    assert_includes q, "coffee"
    assert_includes q, "morning"
    assert_operator q.index("coffee"), :<, (q.index("climate") || q.size),
      "the question's subject must come before the theme term"
  end

  test "card query falls back to the theme when the question is all filler" do
    s = make_survey(theme: "Travel", audience_age: "all",
                    cards: [ { "type" => "multiple_choice", "text" => "Which would you prefer?" } ])
    q = AssetPopulator.new(s).send(:card_query, s.cards[0])

    assert_includes q, "travel", "an all-filler question should fall back to the theme"
  end

  # ── Pexels source (primary when configured) ──────────────────────────────

  PEXELS_PHOTOS = (1..6).map do |i|
    {
      "id" => i, "photographer" => "Photographer #{i}",
      "photographer_url" => "https://www.pexels.com/@photographer-#{i}",
      "alt" => "alt#{i}",
      "src" => {
        "original"  => "https://images.pexels.com/photos/#{i}/p.jpg",
        "landscape" => "https://images.pexels.com/photos/#{i}/p.jpg?w=1200&h=627&fit=crop",
        "portrait"  => "https://images.pexels.com/photos/#{i}/p.jpg?w=800&h=1200&fit=crop",
        "tiny"      => "https://images.pexels.com/photos/#{i}/p.jpg?w=280&h=200&fit=crop"
      }
    }
  end.freeze

  PEXELS_VIDEOS = (1..6).map do |i|
    {
      "id" => 100 + i,
      "image" => "https://images.pexels.com/videos/#{100 + i}/poster.jpeg",
      "user" => { "name" => "Filmmaker #{i}", "url" => "https://www.pexels.com/@filmmaker-#{i}" },
      "video_files" => [
        { "file_type" => "video/mp4", "width" => 540,  "link" => "https://videos.pexels.com/video-files/#{100 + i}/sd.mp4" },
        { "file_type" => "video/mp4", "width" => 720,  "link" => "https://videos.pexels.com/video-files/#{100 + i}/hd.mp4" },
        { "file_type" => "video/mp4", "width" => 2160, "link" => "https://videos.pexels.com/video-files/#{100 + i}/uhd.mp4" }
      ]
    }
  end.freeze

  def with_pexels(photos = PEXELS_PHOTOS, videos = [])
    fake = Object.new
    fake.define_singleton_method(:search) { |**_kw| photos }
    fake.define_singleton_method(:search_videos) { |**_kw| videos }
    stub_method(PexelsClient, :configured?, true) do
      stub_method(PexelsClient, :new, fake) { yield }
    end
  end

  test "when Pexels is configured it sources the background and card images" do
    s = make_survey(theme: "Mountains", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite peak?", "options" => %w[Alps Andes] } ])

    with_pexels { AssetPopulator.new(s).populate! }

    s.reload
    assert_match %r{\Ahttps://images\.pexels\.com/.+w=1920&h=1080}, s.background_image
    assert Survey.sanitize_background_image(s.background_image),
      "Pexels background must pass the sanitizer"
    assert_match %r{\Ahttps://images\.pexels\.com/.+w=720&h=1280}, s.cards[0]["image"],
      "card left panel must get a 9:16 portrait crop"
    assert_match %r{\APhotographer \d\z}, s.cards[0]["image_credit"].to_s,
      "card must carry the photographer credit"
    assert_match %r{\Ahttps://www\.pexels\.com/@}, s.cards[0]["image_credit_url"].to_s,
      "card must carry the photographer link"
  end

  test "mixes video into card art as a 1-in-3 accent, never adjacent" do
    cards = (1..6).map { |i| { "type" => "multiple_choice", "text" => "Q#{i}", "options" => %w[a b] } }
    s = make_survey(theme: "Mountains", audience_age: "18-24", cards: cards)

    with_pexels(PEXELS_PHOTOS, PEXELS_VIDEOS) { AssetPopulator.new(s).populate! }

    s.reload
    media = s.cards.map { |c| c["video"].present? ? :video : (c["image"].present? ? :photo : :none) }
    # 6 eligible cards → the 3rd and 6th prefer video: P P V P P V
    assert_equal [ :photo, :photo, :video, :photo, :photo, :video ], media

    vid = s.cards[2]
    assert_match %r{\Ahttps://videos\.pexels\.com/.+\.mp4\z}, vid["video"]
    assert_includes vid["video"], "/hd.mp4", "picks the ~720p file, not the 4K one"
    assert_match %r{\Ahttps://images\.pexels\.com/}, vid["video_poster"]
    assert_nil vid["image"], "a video card carries no still image"
    assert_match %r{\AFilmmaker \d\z}, vid["image_credit"].to_s
    assert_match %r{\Ahttps://www\.pexels\.com/@}, vid["image_credit_url"].to_s

    # No two videos adjacent (the Rules-of-the-Game variety principle).
    s.cards.each_cons(2) do |a, b|
      refute(a["video"].present? && b["video"].present?, "videos must never sit adjacent")
    end
  end

  test "curated fallback picks carry no photographer credit" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?", "options" => %w[Arsenal Chelsea] } ])

    with_pexels([]) { AssetPopulator.new(s).populate! }

    s.reload
    assert_includes s.cards[0]["image"].to_s, "verto-library/"
    assert_nil s.cards[0]["image_credit"], "curated art has no credit"
  end

  test "Pexels fills card art for themes the curated library doesn't cover" do
    # "Food and Sustainability" has no themed left-panel asset, so without
    # Pexels the welcome + open_ended cards would be blank. With Pexels every
    # non-tap_card gets a portrait, regardless of curated coverage.
    s = make_survey(theme: "Food and Sustainability", audience_age: "under 10's",
                    cards: [
                      { "type" => "welcome_card", "text" => "Hey!" },
                      { "type" => "open_ended",   "text" => "What did you eat today?" }
                    ])

    with_pexels { AssetPopulator.new(s).populate! }

    s.reload
    s.cards.each_with_index do |c, i|
      assert_match %r{\Ahttps://images\.pexels\.com/.+w=720&h=1280}, c["image"].to_s,
        "card #{i} (#{c['type']}) should get a Pexels portrait"
    end
  end

  test "tap_card option_images come from Pexels (landscape) and stay unique; left panel blank" do
    s = make_survey(theme: "Mountains", audience_age: "all",
                    cards: [ { "type" => "tap_card", "text" => "Swipe", "options" => %w[a b c d] } ])

    with_pexels { AssetPopulator.new(s).populate! }

    s.reload
    imgs = Array(s.cards[0]["option_images"])
    assert_equal 4, imgs.size
    assert_equal imgs.size, imgs.uniq.size, "option_images must be unique within a card"
    imgs.each { |u| assert_match %r{\Ahttps://images\.pexels\.com/.+w=800&h=800}, u }
    assert_nil s.cards[0]["image"], "tap_card left panel stays blank with Pexels too"
  end

  test "same seed is deterministic with Pexels" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "options" => %w[a b] } ] * 4
    s1 = make_survey(theme: "Mountains", audience_age: "18-24", cards: cards.deep_dup)
    s2 = make_survey(theme: "Mountains", audience_age: "18-24", cards: cards.deep_dup)

    with_pexels { AssetPopulator.new(s1, seed: "fixed").populate! }
    with_pexels { AssetPopulator.new(s2, seed: "fixed").populate! }

    assert_equal s1.reload.background_image, s2.reload.background_image
    assert_equal s1.cards.map { |c| c["image"] }, s2.cards.map { |c| c["image"] }
  end

  test "falls back to the curated library when Pexels returns nothing" do
    s = make_survey(theme: "Football fans", audience_age: "18-24",
                    cards: [ { "type" => "multiple_choice", "text" => "Favourite team?", "options" => %w[Arsenal Chelsea] } ])

    with_pexels([]) { AssetPopulator.new(s).populate! }

    s.reload
    assert_match %r{/assets/verto-library/backgrounds/}, s.background_image
    assert_includes s.cards[0]["image"], "verto-library/"
  end
end
