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
    @org    = Organisation.create!(name: "O", slug: "stars-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Stars", theme: "T", audience_age: "all",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # Cuprite keeps ONE browser for the whole run; a suite that exits phone-sized
  # breaks everything scheduled after it.
  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_rating(width:, height:)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
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

  # The one that needed measuring rather than believing.
  test "tapping a star does not scroll the card while the confetti flies" do
    open_rating(width: PHONES["iPhone SE"][0], height: PHONES["iPhone SE"][1])

    overflow = -> { page.evaluate_script(<<~JS) }
      (() => {
        const b = document.querySelector(".preview-card.active .split-right > .mt-2")
        return b ? b.scrollHeight - b.clientHeight : null
      })()
    JS

    assert_equal 0, overflow.call, "the rating card overflows before anything is even tapped"

    find(".preview-card.active .rating-star", match: :first).click

    # Sampled DURING the burst — the pieces live about 700ms, and before this
    # fix the scroller grew by ~62px for exactly that window and then healed
    # itself. Checking only after the animation would have found nothing.
    worst = 0
    6.times do
      sleep 0.1
      worst = [ worst, overflow.call.to_i ].max
    end

    assert_equal 0, worst,
                 "the answer scroller grew by #{worst}px while the celebration played. The " \
                 "confetti is absolutely positioned against .rating-stars, so it counts toward " \
                 "that scroller unless .rating-stars takes itself out of the overflow " \
                 "calculation (overflow: clip + overflow-clip-margin)."
  end
end
