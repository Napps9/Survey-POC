require "application_system_test_case"

# The player overlay must cover the VISIBLE rectangle — always, whatever the
# two viewports are doing.
#
# `.preview-overlay` is `position: fixed; inset: 0` plus a height. That is
# over-constrained: `bottom` is dropped, so the box is ANCHORED to the layout
# viewport and SIZED to the visual one. While the two agree, harmless. A soft
# keyboard is where they stop agreeing, and the failure it produced on a real
# iPhone was the card's top off screen, the footer stranded mid-screen, and a
# band of bare <body> between the card and the keyboard.
#
# lib/viewport_height.js used to defend this by INFERRING the platform from
# `innerHeight - visualViewport.height` and freezing its published height when
# the delta looked like a keyboard. Two problems: a height alone cannot fix a
# box that is in the wrong PLACE, and the inference rests on "iOS Safari
# ignores interactive-widget", which is a fact about a browser rather than
# about this code. Browsers move.
#
# So the overlay is now pinned to the measured rectangle instead — height from
# visualViewport.height, position from a translateY of visualViewport.offsetTop
# — and this pins the invariant that makes that correct, rather than the
# arithmetic that implements it.
#
# Headless Chromium has no soft keyboard, so the viewport is stubbed. That is
# the point: the test is about what the overlay does GIVEN a viewport split,
# and a stub states the split exactly instead of hoping a real one shows up.
class PlayerViewportPinTest < ApplicationSystemTestCase
  PHONE   = [ 393, 852 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  # Stands in for an iOS keyboard: the visual viewport shrinks to the band
  # above it and the browser scrolls that band down to reveal the field.
  KEYBOARD_VISIBLE_H = 516
  KEYBOARD_SCROLL    = 200

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "pin-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Pin", theme: "T", audience_age: "all",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [ { "type" => "welcome_card", "title" => "Hi" },
                                            { "type" => "open_ended", "cid" => "o1", "text" => "Say more" } ])
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_player
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".preview-overlay", wait: 5
  end

  def overlay_rect
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(".preview-overlay")
        const r = el.getBoundingClientRect()
        return { top: Math.round(r.top), height: Math.round(r.height),
                 transform: getComputedStyle(el).transform }
      })()
    JS
  end

  def simulate_keyboard(height:, offset:)
    page.execute_script(<<~JS, height, offset)
      const [h, o] = arguments
      const vv = window.visualViewport
      Object.defineProperty(vv, "height",    { get: () => h, configurable: true })
      Object.defineProperty(vv, "offsetTop", { get: () => o, configurable: true })
      vv.dispatchEvent(new Event("resize"))
    JS
    sleep 0.3
  end

  test "with no keyboard the overlay is the whole viewport and carries no transform" do
    open_player
    r = overlay_rect

    assert_equal 0, r["top"]
    assert_in_delta PHONE[1], r["height"], 2

    # Not cosmetic: a transform makes the overlay a containing block for any
    # `position: fixed` DESCENDANT, and the player has one (.regions-overlay).
    # It is acceptable while a keyboard is up — an inset:0 panel against a
    # viewport-sized overlay is still exactly fullscreen — but it must not be
    # imposed on the ordinary case for nothing.
    assert_equal "none", r["transform"],
                 "the overlay carries a transform with no viewport split to cancel"
  end

  test "a split viewport puts the overlay exactly on the visible band" do
    open_player
    simulate_keyboard(height: KEYBOARD_VISIBLE_H, offset: KEYBOARD_SCROLL)
    r = overlay_rect

    # top == offsetTop and height == visualViewport.height together mean the
    # overlay lands precisely over what the respondent can see. Get the height
    # right but not the offset and the box is the correct size in the wrong
    # place — which is the bug this replaced, and it looks like a huge gap
    # under the card rather than like a positioning fault.
    assert_in_delta KEYBOARD_SCROLL, r["top"], 2,
                    "the overlay did not follow the visual viewport's scroll — bare <body> " \
                    "will show below it, with the footer stranded in the middle"
    assert_in_delta KEYBOARD_VISIBLE_H, r["height"], 2,
                    "the overlay is not sized to the visible band"
  end

  test "the overlay returns to the full viewport when the keyboard closes" do
    open_player
    simulate_keyboard(height: KEYBOARD_VISIBLE_H, offset: KEYBOARD_SCROLL)
    simulate_keyboard(height: PHONE[1], offset: 0)
    r = overlay_rect

    # A stale transform outliving the split leaves the card shifted down the
    # screen with nothing below it — the same class of bug as a stale frozen
    # height, which is why both edges are pinned.
    assert_equal 0, r["top"]
    assert_in_delta PHONE[1], r["height"], 2
    assert_equal "none", r["transform"], "the transform outlived the viewport split"
  end
end
