require "application_system_test_case"

# The hidden way into Test Mode from a LIVE play link (player/_test_mode_hatch,
# player_controller.js#testHoldStart → #enterTestMode). It exists for the person
# demoing a Verto on the real link — a facilitator at an event, a creator on a
# borrowed phone — whose run would otherwise sit in the creator's results.
#
# Both halves of it are the point, and only a browser can hold either:
#
#  - it MUST work for someone who was told about it, and
#  - it MUST NOT happen to anyone who wasn't.
#
# The second is the one worth a test. A respondent who trips into Test Mode has
# their real answers silently discarded, so the assertion that a tap, a short
# press and a press-that-turned-into-a-drag all leave the player alone is doing
# more work here than the happy path is.
class TestModeHatchTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "multiple_choice", "text" => "Pick one", "options" => %w[a b c] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "hatch-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Hatch", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def open_player
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".test-hatch-hotspot", visible: :all, wait: 5
  end

  # The hotspot's centre in viewport coordinates. It is deliberately invisible
  # (no background, no label), so there is nothing for Capybara's own click to
  # aim at descriptively — the gesture has to be driven at the pixel level, the
  # same way a finger would.
  def hotspot_centre
    r = evaluate_script(<<~JS)
      (() => {
        const b = document.querySelector(".test-hatch-hotspot").getBoundingClientRect()
        return { x: b.left + b.width / 2, y: b.top + b.height / 2 }
      })()
    JS
    [ r["x"], r["y"] ]
  end

  # A point inside the hatch's TOUCH target but outside its 34×26 layout box —
  # the ::after that supplies the 44px minimum. Above the box rather than beside
  # it, because that is the edge a thumb reaching for the top-left corner of a
  # phone actually overshoots.
  def hotspot_overshoot
    r = evaluate_script(<<~JS)
      (() => {
        const b = document.querySelector(".test-hatch-hotspot").getBoundingClientRect()
        return { x: b.left + b.width / 2, y: b.top - 5 }
      })()
    JS
    [ r["x"], r["y"] ]
  end

  # Press and hold, optionally sliding partway through. CDP's mouse input is
  # what Chrome turns into the pointerdown/pointermove/pointerup the hatch
  # listens for, so this is a real gesture and not a synthesised event.
  def press_and_hold(seconds, drag_by: 0, at: nil)
    x, y = at || hotspot_centre
    mouse = page.driver.browser.mouse
    mouse.move(x: x, y: y).down
    if drag_by.positive?
      sleep 0.2
      mouse.move(x: x + drag_by, y: y)
    end
    sleep seconds
    mouse.up
  end

  def chip_shown?
    has_selector?(".test-hatch-confirm", wait: 1)
  end

  test "a hold arms the chip, and tapping it lands in Test Mode with a way back" do
    open_player
    refute chip_shown?, "the chip must not be showing before anyone touches anything"

    press_and_hold 2.4

    assert_selector ".test-hatch-confirm", wait: 2
    find(".test-hatch-confirm").click

    assert_current_path "/test/live/#{@survey.publish_token}", wait: 5
    assert_selector ".play-test-frame", wait: 5
    # visible: :all — the sentence is clipped to 1px now (the ring is what a
    # tester sees), so Capybara's visibility rules will not find it otherwise.
    assert_selector ".play-test-note", text: I18n.t("player.test_mode_banner"),
                    visible: :all, wait: 5
    # And back out again, to the very link they arrived on.
    click_link I18n.t("player.exit_test_mode")
    assert_current_path "/play/#{@survey.publish_token}", wait: 5
  end

  test "an ordinary tap, a short press and a press that becomes a drag all do nothing" do
    open_player

    x, y = hotspot_centre
    page.driver.browser.mouse.move(x: x, y: y).down.up
    refute chip_shown?, "a tap must not arm it"

    press_and_hold 0.9
    refute chip_shown?, "a press shorter than the hold must not arm it"

    # A scroll or a swipe that happens to start on the hotspot is the realistic
    # accident, and it outlasts the hold timer — the slop guard is what stops it.
    press_and_hold 2.4, drag_by: 40
    refute chip_shown?, "a press that travelled is a swipe, not a hold"

    assert_current_path "/play/#{@survey.publish_token}"
  end

  # The target is invisible, so there is no edge to aim at and no way to tell a
  # miss from a Verto that simply doesn't have the hatch — and the buzz that
  # would have said "you're on it" is a no-op on iOS. A press that lands just
  # outside the 34×26 box is therefore the ordinary case, not the careless one,
  # and it has to arm. The layout box stays 34×26 (growing it would push every
  # Verto's deck down); the ::after is what a finger gets to hit.
  test "a hold that lands just above the box still arms it" do
    open_player

    box_h = evaluate_script(%{document.querySelector(".test-hatch-hotspot").getBoundingClientRect().height})
    assert_equal 26, box_h.round, "the visible bar's height must not have changed"

    press_and_hold 2.4, at: hotspot_overshoot
    assert_selector ".test-hatch-confirm", wait: 2
  end

  test "an armed chip that is left alone hides itself again" do
    open_player
    press_and_hold 2.4
    assert_selector ".test-hatch-confirm", wait: 2

    # TEST_ARM_MS is 5s; wait it out and the door closes on its own rather than
    # sitting open for whoever picks the phone up next.
    assert_no_selector ".test-hatch-confirm", wait: 8
    assert_current_path "/play/#{@survey.publish_token}"
  end

  test "Test Mode reached this way records nothing" do
    open_player
    press_and_hold 2.4
    find(".test-hatch-confirm").click
    assert_selector ".play-test-frame", wait: 5

    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    all(".preview-card[data-card-index] .choice-item, .preview-card[data-card-index] [data-picker-target='item']").first&.click
    click_button "Next" if has_button?("Next", wait: 2)

    assert_equal 0, @survey.reload.responses.count,
                 "a run in Test Mode must never reach the creator's results"
  end
end
