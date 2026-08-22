require "application_system_test_case"

# _revealField scrolls a focused text field clear of the keyboard, inside the
# box that owns the card's scroll — because the browser's own scrollIntoView
# would scroll the VISUAL viewport instead and drag the whole overlay off
# screen, which is the bug it was written to replace.
#
# The arithmetic it depends on is pinned separately, in visible_band_test: the
# floor is the lower edge of the band the respondent can SEE, which is not
# visualViewport.height unless offsetTop happens to be zero. That test states
# the numbers exactly. This one states the thing the numbers are for, because
# an arithmetic test cannot notice the feature being switched off — and this
# routine is unusually easy to switch off by accident. Two ways found while
# working on it: bail early on a box it does not recognise, or never be reached
# because the field was already focused and no focusin ever fires.
class PlayerRevealFieldTest < ApplicationSystemTestCase
  PHONE   = [ 393, 852 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  # Twelve options plus "+ Other" is the shape that puts a text field inside a
  # box with somewhere to scroll. No image on the card, deliberately: a hero
  # would be dropped by _watchTyping the moment the field takes focus, and that
  # relayout moves the scroller on its own — a different mechanism, and it
  # would mask this one.
  CARDS = [
    { "type" => "welcome_card", "title" => "Hi" },
    { "type" => "multiple_choice", "cid" => "m1", "text" => "Which of these applies?",
      "allow_other" => true,
      "options" => (1..12).map { |i| "Option number #{i}" } }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "rev-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Reveal", theme: "T", audience_age: "all",
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

  def open_other_field
    page.driver.browser.resize(width: PHONE[0], height: PHONE[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next"
    assert_selector ".preview-card.active .other-cta-btn", wait: 5
    find(".preview-card.active .other-cta-btn").click
    assert_selector ".preview-card.active .other-panel textarea", wait: 5
    sleep 0.4
  end

  test "focusing a field below the fold brings it into view" do
    open_other_field

    # Opening the panel focuses the textarea itself, so a second .focus() would
    # be a no-op and fire no focusin at all — which is precisely how an earlier
    # draft of this test managed to pass against broken code. Blur first, and
    # park the scroller at the top so the field is genuinely out of sight.
    before = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const el   = card.querySelector(".other-panel textarea")
        const box  = el.closest(".split-right > .mt-2, .split-right > .other-block, " +
                                ".split-right > .play-consent-main")
        el.blur()
        box.scrollTop = 0
        return { scrollTop: Math.round(box.scrollTop),
                 room: Math.round(box.scrollHeight - box.clientHeight),
                 fieldBottom: Math.round(el.getBoundingClientRect().bottom),
                 boxBottom: Math.round(box.getBoundingClientRect().bottom) }
      })()
    JS

    assert_operator before["room"], :>, 0,
                    "the scroller has nowhere to go, so this test could not detect the " \
                    "reveal working or not working — the fixture is wrong, not the app"
    assert_operator before["fieldBottom"], :>, before["boxBottom"],
                    "the field is already fully inside its box, so there is nothing to " \
                    "reveal (#{before.inspect})"

    page.execute_script(%(document.querySelector(".preview-card.active .other-panel textarea").focus()))
    sleep 1.0   # 300ms timer, then a smooth scroll

    after = page.evaluate_script(<<~JS)
      (() => {
        const el  = document.querySelector(".preview-card.active .other-panel textarea")
        const box = el.closest(".split-right > .mt-2, .split-right > .other-block, " +
                               ".split-right > .play-consent-main")
        return { scrollTop: Math.round(box.scrollTop),
                 fieldBottom: Math.round(el.getBoundingClientRect().bottom),
                 boxBottom: Math.round(box.getBoundingClientRect().bottom) }
      })()
    JS

    assert_operator after["scrollTop"], :>, before["scrollTop"],
                    "focusing a field that was out of sight did nothing. _revealField is " \
                    "the only thing that scrolls it — the browser's own scrollIntoView is " \
                    "deliberately not relied on here, because it scrolls the visual " \
                    "viewport and takes the overlay with it."
    assert_operator after["fieldBottom"], :<=, after["boxBottom"] + 1,
                    "the field came up but not far enough to be inside its own box"
  end

  test "focusing a field already in view leaves the scroller alone" do
    open_other_field

    # Same blur-first dance, but this time scrolled so the field is visible.
    # The reveal must be a no-op: every extra movement after the card has
    # settled is one the respondent reads as a glitch.
    before = page.evaluate_script(<<~JS)
      (() => {
        const card = document.querySelector(".preview-card.active")
        const el   = card.querySelector(".other-panel textarea")
        const box  = el.closest(".split-right > .mt-2, .split-right > .other-block, " +
                                ".split-right > .play-consent-main")
        el.blur()
        box.scrollTop = box.scrollHeight   // clamps to the bottom
        return { scrollTop: Math.round(box.scrollTop),
                 fieldBottom: Math.round(el.getBoundingClientRect().bottom),
                 boxBottom: Math.round(box.getBoundingClientRect().bottom) }
      })()
    JS

    assert_operator before["fieldBottom"], :<=, before["boxBottom"] + 1,
                    "the field is not in view to start with (#{before.inspect})"

    page.execute_script(%(document.querySelector(".preview-card.active .other-panel textarea").focus()))
    sleep 1.0

    after_top = page.evaluate_script(<<~JS)
      (() => {
        const el  = document.querySelector(".preview-card.active .other-panel textarea")
        const box = el.closest(".split-right > .mt-2, .split-right > .other-block, " +
                               ".split-right > .play-consent-main")
        return Math.round(box.scrollTop)
      })()
    JS

    assert_equal before["scrollTop"], after_top,
                 "the scroller moved for a field that was already in view"
  end
end
