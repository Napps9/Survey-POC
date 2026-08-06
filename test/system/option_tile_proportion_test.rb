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

  # Once the shed order takes the tiles away (player_shed_order_test) there is
  # no banner left to measure — the artwork became a 34px swatch on a row.
  # That is the same invariant reached another way: what must never happen is
  # a DISTORTED tile, and a tile that isn't there can't be.
  def art_shed?
    page.has_css?(".preview-card.active .choice-grid.art-off", wait: 1)
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
      next if art_shed? # no banner tile to be out of proportion

      ratios.each do |ratio|
        assert ratio <= FLATTEST,
               "#{name} (#{width}x#{height}) flattened a tile to #{ratio}:1 — a stripe, not a tile"
        assert ratio >= TALLEST,
               "#{name} (#{width}x#{height}) stretched a tile to #{ratio}:1 — taller than it was drawn"
      end
    end
  end

  # The specific shape that exposed it: the same phone, turned. It used to
  # answer with a 2:1 tile upright and a 4.6:1 smear sideways. Now it either
  # keeps the proportion or drops the artwork — what it must never do again is
  # show the same picture in two different shapes.
  test "turning a phone sideways never restates a tile in a different shape" do
    upright = tile_ratios_at(393, 660).max
    assert upright.between?(TALLEST, FLATTEST), "upright should be a banner, got #{upright}:1"

    sideways = tile_ratios_at(844, 390).max
    if art_shed?
      assert_in_delta 1.0, sideways, 0.35,
                      "a shed tile is a square swatch on a row, got #{sideways}:1"
    else
      assert_in_delta upright, sideways, 0.6,
                      "kept as a banner, it should be the same banner " \
                      "(upright #{upright}:1, sideways #{sideways}:1)"
    end
  end
end
