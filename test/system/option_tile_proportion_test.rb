require "application_system_test_case"

# An option tile is a banner: roughly two and a half times wider than it is
# tall, which is the proportion it was drawn at. Its height used to be
# whatever the grid row had left over, so the same six options on the same
# phone were 2:1 upright and 4.6:1 turned sideways — the artwork squeezed into
# a coloured band. The tile now takes its height as a share of its own column
# width, and this is the guard on that: a bound expressed as a ratio can only
# really be checked by measuring one.
class OptionTileProportionTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze

  # The band the tile is allowed to live in. Desktop, which nobody has ever
  # complained about, sits at 2.37:1 — these are that, with room either side.
  FLATTEST = 2.70
  TALLEST  = 1.60

  SHAPES = [
    [ "Galaxy Fold cover",   280,  653 ],
    [ "iPhone SE",           375,  553 ],
    [ "iPhone 15",           393,  660 ],
    [ "iPhone 15 sideways",  844,  390 ],
    [ "iPad mini portrait",  768,  954 ],
    [ "iPad Pro portrait",  1024, 1290 ],
    [ "laptop",             1280,  800 ]
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "tile-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Tiles", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Welcome" },
                                     { "type" => "select_many_grid", "cid" => "c1",
                                       "text" => "Which themes should we build more sessions around?",
                                       "image" => "/nope.jpg",
                                       "options" => [ "AI and automation", "Brand building",
                                                      "Measurement", "Creative craft",
                                                      "Leadership", "Sustainability" ] }
                                   ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def tile_ratios_at(width, height)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"

    page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".preview-card.active .choice-card-bg")].map(el => {
        const r = el.getBoundingClientRect()
        return r.height > 0 ? +(r.width / r.height).toFixed(2) : 0
      })
    JS
  end

  SHAPES.each do |name, width, height|
    test "option tiles keep their proportion on a #{name}" do
      ratios = tile_ratios_at(width, height)

      assert_equal 6, ratios.length, "expected all six options to be laid out"

      ratios.each do |ratio|
        assert ratio <= FLATTEST,
               "#{name} (#{width}x#{height}) flattened a tile to #{ratio}:1 — a stripe, not a tile"
        assert ratio >= TALLEST,
               "#{name} (#{width}x#{height}) stretched a tile to #{ratio}:1 — taller than it was drawn"
      end
    end
  end

  # ── One size, whatever the card holds ────────────────────────────────────
  #
  # The band above says a tile is never DISTORTED. This says something
  # stronger and newer: within one Verto every tile is the same size, so paging
  # through a deck the artwork doesn't visibly breathe in and out.
  #
  # It used to. The tile stated a proportion range (38cqw to 58cqw) and flexed
  # to absorb whatever height the row had spare, so option count decided it: on
  # a 393px phone a four-option grid drew a 100px tile, six drew 75px and nine
  # drew 66px. Inside one card it was worse — a label that wrapped to three
  # lines where its neighbours wrapped to two took the difference out of its
  # own tile, so two tiles side by side came out different heights. The tile is
  # a single aspect-ratio now and neither can happen.

  COUNTS = [ 4, 6, 9 ].freeze

  def counted_survey
    opts = %w[Automation Brand Measurement Creative Leadership Sustainability
              Partnerships Innovation Insight Content]
    cards = [ { "type" => "welcome_card", "title" => "Welcome" } ]
    COUNTS.each_with_index do |n, i|
      cards << { "type" => "select_one_grid", "cid" => "n#{i}",
                 "text" => "Which of these #{n}?", "image" => "/nope.jpg",
                 "options" => opts.first(n) }
    end
    s = @org.surveys.create!(title: "Counts", theme: "Th", audience_age: "adults",
                             key_insight: "k", default_locale: "en", locales: [ "en" ],
                             cards: cards)
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    s
  end

  # Tile height and ratio on the card `step` clicks past the welcome card.
  def tile_box_at(step)
    step.times { click_button "Next" }
    sleep 0.4 # the fit runs a frame after the card lands
    page.evaluate_script(<<~JS)
      (() => {
        const els = [...document.querySelectorAll(".preview-card.active .choice-card-bg")]
        if (!els.length) return null
        const boxes = els.map(e => e.getBoundingClientRect())
        return { h: +Math.max(...boxes.map(b => b.height)).toFixed(1),
                 hMin: +Math.min(...boxes.map(b => b.height)).toFixed(1),
                 ratio: +(boxes[0].width / boxes[0].height).toFixed(2) }
      })()
    JS
  end

  [ [ "iPhone 15", 393, 660 ], [ "Galaxy Fold cover", 280, 653 ], [ "iPad mini portrait", 768, 954 ] ].each do |name, w, h|
    test "every tile in a deck is the same size on a #{name}" do
      survey = counted_survey
      page.driver.browser.resize(width: w, height: h)
      visit "/play/#{survey.publish_token}"
      dismiss_cookie_banner
      click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)

      seen = []
      COUNTS.each_index do |i|
        box = tile_box_at(i.zero? ? 1 : 1)
        next if box.nil?
        # Within the card first: a label wrapping further than its neighbour's
        # must not shorten its own tile.
        assert_in_delta box["h"], box["hMin"], 1.0,
                        "#{name}: tiles on the #{COUNTS[i]}-option card differ by " \
                        "#{(box["h"] - box["hMin"]).round(1)}px within the same card"
        seen << box
      end

      assert_operator seen.length, :>=, 2, "not enough cards kept their artwork to compare"
      heights = seen.map { |b| b["h"] }
      assert_in_delta heights.max, heights.min, 1.0,
                      "#{name}: option count changed the tile — #{COUNTS.first(seen.length).zip(heights).inspect}. " \
                      "A four-option card and a nine-option card must draw the same tile."
    end
  end

  # The specific shape that exposed it: the same phone, turned. It used to
  # answer with a 2:1 tile upright and a 4.6:1 smear sideways. Nothing sheds
  # the artwork any more — the tiles stay at every size — so the answer is
  # always the same banner, never the same picture in two different shapes.
  test "turning a phone sideways never restates a tile in a different shape" do
    upright = tile_ratios_at(393, 660).max
    assert upright.between?(TALLEST, FLATTEST), "upright should be a banner, got #{upright}:1"

    sideways = tile_ratios_at(844, 390).max
    assert_in_delta upright, sideways, 0.6,
                    "kept as a banner, it should be the same banner " \
                    "(upright #{upright}:1, sideways #{sideways}:1)"
  end
end
