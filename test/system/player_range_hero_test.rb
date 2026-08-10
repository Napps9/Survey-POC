require "application_system_test_case"

# A range card's animation gets the phone, not the white space.
#
# The animation is `.nps-lottie` — the class name is a fossil; NPS proper
# dropped the strip long ago and only range cards render it — and it is the
# app's one slider-reactive animation: five Lottie frames keyed to the thumb.
# The mobile CSS used to clamp its strip to 104-190px (under a comment written
# for NPS) and hand every spare pixel to the answer panel, where it painted as
# blank centring around a ~240px slider. Desktop gives the same animation a
# 425x680 panel with a 380px character.
#
# The fix inverts who absorbs the spare, for range only: the answer panel is
# content-sized and unshrinkable (its intrinsic height IS its claim — a track,
# a thumb and a row of scale words cost the same on every phone), and the
# strip is the card's only grow item. These tests pin the inversion, not any
# particular pixel: the strip must OUTGROW the old cap where there is room,
# must YIELD to the answer where there isn't, and the answer may cost a scroll
# but may never cost a control.
class PlayerRangeHeroTest < ApplicationSystemTestCase
  DESKTOP = [ 1280, 900 ].freeze
  OLD_CAP = 190 # the ceiling of the removed clamp(104px, 20svh, 190px)

  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    # 5 options, every label <= 18 chars → resolved_slider_axis: horizontal
    { "type" => "range", "cid" => "r1", "text" => "How confident do you feel?",
      "options" => [ "Not at all", "A little", "Somewhat", "Fairly", "Very" ],
      "range_theme" => "koala" },
    # Vertical by LABEL LENGTH (>18 chars), not by count: Survey enforces a
    # 5-point scale on range cards (enforce_range_scale), so a 6-option card
    # is truncated on save and the count heuristic can never trip in data
    # that went through the model. Long labels are the one authoring path
    # that really produces a vertical slider.
    { "type" => "range", "cid" => "r2", "text" => "How does the direction feel?",
      "options" => [ "Completely the wrong direction", "Somewhat off course", "Neutral",
                     "Broadly the right direction", "Exactly the right direction" ],
      "range_theme" => "koala" }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "rh-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "RangeHero", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # Cuprite keeps one browser for the run; a test that resizes and doesn't put
  # it back breaks whatever runs after it.
  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_at(width, height, card: 1, root_font: nil)
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    page.execute_script("document.documentElement.style.fontSize = '#{root_font}'") if root_font
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    card.times { click_button "Next" }
    sleep 0.35 # layout + the lottie mount settle a frame after the card lands
  end

  def geometry(scroll_to_bottom: false)
    page.evaluate_script(<<~JS)
      (() => {
        const body = document.querySelector(".preview-body")
        if (#{scroll_to_bottom}) body.scrollTop = body.scrollHeight
        const card  = document.querySelector(".preview-card.active")
        const on    = (el) => {
          const r = el?.getBoundingClientRect()
          return r ? r.top >= -1 && r.bottom <= window.innerHeight + 1 : null
        }
        const h = (el) => el ? +el.getBoundingClientRect().height.toFixed(1) : null
        const mount = card.querySelector(".nps-lottie-mount")
        const labels = [...card.querySelectorAll(".slider-label-text")]
        return {
          axis:    card.querySelector(".slider-wrap")?.dataset.sliderAxisValue,
          strip:   h(card.querySelector(".split-left")),
          mountH:  h(mount),
          mountShown: mount ? getComputedStyle(mount).display !== "none" : null,
          scroll:  Math.max(0, body.scrollHeight - body.clientHeight),
          trackOn: on(card.querySelector(".slider-track")),
          labelsOn: labels.length ? labels.every(on) : null,
          nextOn:  on(document.querySelector(".preview-btn-next:not(.hidden), .preview-btn-finish:not(.hidden)"))
        }
      })()
    JS
  end

  test "on a phone the strip outgrows the old cap and nothing scrolls" do
    open_at(393, 660)
    g = geometry

    assert_equal "horizontal", g["axis"], "sanity: short labels resolve horizontal"
    assert_operator g["strip"], :>, OLD_CAP + 1,
                    "the strip is #{g["strip"]}px — the inversion should carry it past the " \
                    "removed #{OLD_CAP}px cap, not merely to it"
    assert g["mountShown"], "the animation mount must be visible"
    assert_operator g["mountH"], :>, OLD_CAP,
                    "the ANIMATION (#{g["mountH"]}px) should outgrow the whole old strip, " \
                    "not just the band around it"
    assert g["trackOn"] && g["labelsOn"] && g["nextOn"],
           "growing the hero must cost nothing: track/labels/Next all on screen"
    assert_operator g["scroll"], :<=, 1, "a plain horizontal range card needs no scroll"
  end

  test "sideways, the hero yields to the answer and the controls survive" do
    open_at(844, 390)
    g = geometry

    assert_operator g["strip"], :>=, 59,
                    "the strip may shrink toward its floor, never below it"
    assert g["mountShown"] && g["mountH"].positive?, "the animation never disappears entirely"
    assert g["trackOn"] && g["labelsOn"] && g["nextOn"],
           "short viewports pay with animation size, not with controls"

    # The usable-controls proof is using one: advance off the card.
    click_button "Next"
    sleep 0.35
    assert_equal "vertical", page.evaluate_script(
      "document.querySelector('.preview-card.active .slider-wrap')?.dataset.sliderAxisValue"
    ), "Next should land on the vertical card — the button did something"
  end

  # A vertical slider is the one range answer tall enough to outgrow a short
  # phone. The bargain: the strip drops to its floor first, and whatever still
  # doesn't fit SCROLLS — the baseline layout clipped it invisibly instead
  # (overflow:hidden on a stretch-clamped card), which is an answer silently
  # costing a control.
  test "a vertical slider may cost a scroll, never a control" do
    open_at(844, 390, card: 2)
    g = geometry(scroll_to_bottom: true)

    assert_equal "vertical", g["axis"], "sanity: the long-label card resolves vertical"
    assert g["mountShown"] && g["mountH"].positive?, "the animation holds its floor"
    assert g["trackOn"], "after scrolling, the track must be fully on screen"
    assert g["labelsOn"], "after scrolling, every scale label must be on screen"
    assert g["nextOn"], "Next stays reachable"
  end

  test "a raised browser font may scroll, never clip" do
    open_at(375, 553, card: 2, root_font: "20px")
    g = geometry(scroll_to_bottom: true)

    assert_equal "vertical", g["axis"]
    assert g["trackOn"] && g["labelsOn"] && g["nextOn"],
           "at a 20px root the vertical card may scroll; every control must remain reachable"
  end
end
