require "application_system_test_case"

# The rating card's four notes from the 3rd-round mobile sheet, and the one
# among them whose stated cause was wrong.
#
# Three are presentation: the stars were small, their points were needle-sharp
# because a font glyph's points cannot be rounded by CSS, and the two end
# captions were pinned to the outer edges of the ANSWER PANEL rather than
# sitting under the stars they name.
#
# The fourth — "a weird scrollbar appear right hand side when you tap a star" —
# was reported as a consequence of the card being too tall. It is not. It is
# the celebration confetti: .rating-burst's pieces are absolutely positioned
# against the star row and fly outward past the answer scroller, and an
# absolutely positioned descendant whose containing block sits inside a
# scroller counts toward that scroller's scrollHeight. Measured on an iPhone
# SE: 0px of overflow at rest, 62px the moment a star was tapped, back to 0
# once the animation finished. A scrollbar that appears for two-thirds of a
# second and leaves.
#
# So the test that matters here measures the scroller ACROSS the animation,
# not before and after it — the window in between is the entire bug.
class RatingStarsTest < ApplicationSystemTestCase
  PHONES  = { "iPhone 15" => [ 393, 852 ], "iPhone SE" => [ 375, 667 ] }.freeze
  DESKTOP = [ 1280, 900 ].freeze

  CARDS = [
    { "type" => "welcome_card", "title" => "Hi" },
    { "type" => "rating", "cid" => "rt1", "text" => "How would you rate this session overall?",
      "image" => "/nope.jpg", "options" => [ "Very poor", "Excellent" ] }
  ].freeze

  def setup
    super
    @org = Organisation.create!(name: "O", slug: "stars-#{SecureRandom.hex(3)}")
    # "T" matches no RATING_ICON_THEMES keyword, so this is the ★ kind.
    @survey = build_survey("T")
    # …and this one is not. A themed Verto swaps the star for an emoji
    # (ApplicationHelper::RATING_ICON_THEMES — "space"/"rocket" gives 🚀), which
    # is a different glyph at a different size and, it turned out, a different
    # answer to the overflow question. See the confetti test at the bottom.
    @themed = build_survey("Space rocket mission")
  end

  def build_survey(theme)
    s = @org.surveys.create!(title: "Stars #{theme}", theme: theme, audience_age: "all",
                             key_insight: "k", default_locale: "en", locales: [ "en" ],
                             cards: CARDS)
    s.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
    s
  end

  # Cuprite keeps ONE browser for the whole run; a suite that exits phone-sized
  # breaks everything scheduled after it.
  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_rating(width:, height:, survey: @survey)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    sleep 0.5
    assert_equal "rating", find(".preview-card.active")["data-card-type"]
  end

  def geometry
    page.evaluate_script(<<~JS)
      (() => {
        const card  = document.querySelector(".preview-card.active")
        const stars = Array.from(card.querySelectorAll(".rating-star"))
        const labs  = Array.from(card.querySelectorAll(".rating-labels > .rating-label"))
        if (!stars.length || labs.length < 2) return null
        const mid = (el) => { const r = el.getBoundingClientRect(); return r.left + r.width / 2 }
        return {
          size:      +stars[0].getBoundingClientRect().width.toFixed(1),
          masked:    getComputedStyle(stars[0]).maskImage !== "none",
          firstDrift: +Math.abs(mid(stars[0]) - mid(labs[0])).toFixed(1),
          lastDrift:  +Math.abs(mid(stars[stars.length - 1]) - mid(labs[labs.length - 1])).toFixed(1)
        }
      })()
    JS
  end

  PHONES.each do |name, (w, h)|
    test "on an #{name} the stars are a real touch target with softened points" do
      open_rating(width: w, height: h)
      g = geometry
      assert g, "no stars rendered"

      # 44px is the iOS touch minimum; these used to be a 36px glyph.
      assert_operator g["size"], :>=, 44,
                      "the stars render at #{g['size']}px — below the touch minimum, and the " \
                      "note asked for them bigger, not merely adequate."
      assert g["masked"],
             "the star is being painted as a font glyph again. A glyph's points cannot be " \
             "rounded by CSS, which is the whole reason this kind is drawn as a mask " \
             "('could we have stars where the points arent sharp?')."
    end

    test "on an #{name} the end captions sit under the end stars" do
      open_rating(width: w, height: h)
      g = geometry

      assert_operator g["firstDrift"], :<=, 2,
                      "the first caption is #{g['firstDrift']}px off the first star's centre. " \
                      "The captions ride the stars' own grid tracks precisely so this cannot " \
                      "drift — if it has, the row is being laid out against the panel again."
      assert_operator g["lastDrift"], :<=, 2,
                      "the last caption is #{g['lastDrift']}px off the last star's centre."
    end
  end

  # The one that needed measuring rather than believing — twice.
  #
  # First pass blamed the card's height, and it is not that: it is the
  # celebration confetti. The pieces fly up to ~112px from the tapped star, and
  # anything reaching past a scroll container counts toward what that container
  # can scroll, so a scrollbar appeared for the two-thirds of a second the
  # animation ran and then healed itself.
  #
  # Second pass found the first FIX was half a fix, and this test is why it got
  # through. It tapped ONE star, ONCE, on a ★ card. The burst is randomised —
  # angle, distance and scale per piece — so a single tap can come back clean by
  # luck; and the ★ is the one glyph small enough that `overflow: clip` with an
  # 80px margin usually contained it. Re-measured properly, eight taps per
  # configuration: ★ overflowed on 1 of 8 taps by up to 10px, and a THEMED
  # (emoji) card overflowed on 8 of 8 by 17–47px. So the confetti now lives on
  # the overlay in viewport space, outside the scroller entirely, and this test
  # runs both glyph kinds and taps repeatedly.
  #
  # If you are tempted to trim this back to one tap: that is the exact edit that
  # let a broken build ship with a green suite.
  TAPS = 5

  { "star" => :@survey, "themed emoji" => :@themed }.each do |kind, ivar|
    test "tapping a #{kind} rating never scrolls the card while the confetti flies" do
      survey = instance_variable_get(ivar)
      open_rating(width: PHONES["iPhone SE"][0], height: PHONES["iPhone SE"][1], survey: survey)

      overflow = -> { page.evaluate_script(<<~JS).to_i }
        (() => {
          const b = document.querySelector(".preview-card.active .split-right > .mt-2")
          return b ? b.scrollHeight - b.clientHeight : 0
        })()
      JS

      assert_equal 0, overflow.call, "the rating card overflows before anything is even tapped"

      worst = 0
      TAPS.times do |n|
        # A different star each time, so the burst's origin moves and the random
        # draw is resampled — one tap is not a measurement of a random thing.
        stars = all(".preview-card.active .rating-star")
        stars[n % stars.size].click
        # Sampled DURING the burst; the pieces live about 700ms and then tidy
        # up after themselves, so checking afterwards finds nothing either way.
        8.times do
          sleep 0.09
          worst = [ worst, overflow.call ].max
        end
      end

      assert_equal 0, worst,
                   "the answer scroller grew by #{worst}px while the celebration played on a " \
                   "#{kind} card. The burst layer must stay OUT of the scroller — it is " \
                   "parented on .preview-overlay and positioned in viewport coordinates for " \
                   "exactly this reason (rating_controller#_burst). Clipping it inside " \
                   ".rating-stars is not enough: that only removes what lands beyond the clip " \
                   "margin, which a ★ mostly does and an emoji never does."
    end
  end

  # The other half of the same change: taking the confetti out of the card must
  # not take the confetti away.
  test "the burst still renders, anchored on the star that was tapped" do
    open_rating(width: PHONES["iPhone 15"][0], height: PHONES["iPhone 15"][1], survey: @themed)
    all(".preview-card.active .rating-star")[2].click

    burst = page.evaluate_script(<<~JS)
      (() => {
        const layer = document.querySelector(".rating-burst")
        if (!layer) return null
        const star = document.querySelectorAll(".preview-card.active .rating-star")[2]
                             .getBoundingClientRect()
        const l = layer.getBoundingClientRect()
        return {
          host:    layer.parentElement.className.split(" ")[0],
          pieces:  layer.querySelectorAll(".rating-burst-piece").length,
          driftX:  Math.abs(l.left - (star.left + star.width  / 2)),
          driftY:  Math.abs(l.top  - (star.top  + star.height / 2)),
          inScroller: !!layer.closest(".split-right > .mt-2")
        }
      })()
    JS

    assert burst, "no confetti at all — the celebration was removed rather than relocated"
    assert_operator burst["pieces"], :>, 0, "the burst layer is empty"
    assert_equal "preview-overlay", burst["host"],
                 "the burst is parented on #{burst['host']}; it belongs on the overlay, " \
                 "outside the answer scroller"
    assert_not burst["inScroller"],
               "the burst is back inside the answer scroller, which is the whole bug"
    assert_operator burst["driftX"], :<=, 2, "the burst is not centred on the star horizontally"
    assert_operator burst["driftY"], :<=, 2, "the burst is not centred on the star vertically"
  end
end
