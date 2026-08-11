require "application_system_test_case"

# The tap card's swipe. The copy always promised the gesture ("Swipe to
# respond", cursor: grab) but only the buttons ever answered; a real drag fell
# through to the browser, which on phones read a horizontal pull as history
# navigation. The fix is a pointer drag on the top card (tap-stack#dragStart)
# plus touch-action: none so the sequence is ours to interpret — both pinned
# here, in the prioritise_touch_test manner: Cuprite has no touch synthesis,
# so the sequences are synthetic PointerEvents, which is faithful because the
# controller listens for exactly these events on exactly these targets.
#
# The end-of-deck face (.rotate-complete) is asserted here too — the swipe is
# how a respondent gets there.
class TapCardSwipeTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "tap_card", "cid" => "c1", "text" => "React to these",
      "options" => [ "Races are too predictable", "Tickets cost too much", "Sprints are great" ] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "swipe-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Swipe", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def open_tap_card
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # past the welcome card
    assert_selector ".preview-card.active .rotate-card", count: 3, wait: 5
  end

  def results
    JSON.parse(evaluate_script(
      "document.querySelector('.preview-card.active .rotate-wrap')?.dataset?.swipeResults || '{}'"
    ))
  end

  # The top card is the first one whose INLINE opacity isn't "0" — _commit
  # zeroes the flung card's inline style synchronously, whereas the computed
  # opacity lags through the 350ms fling transition.
  def top_card_statement
    evaluate_script(<<~JS)
      (() => {
        const cards = [...document.querySelectorAll('.preview-card.active .rotate-card')]
        const top = cards.find((c) => c.style.opacity !== '0')
        return top ? top.querySelector('span').textContent.trim() : null
      })()
    JS
  end

  # Presses the top card and drags by (dx, dy) fractions of the stack's size,
  # ending with `terminal` at the dragged position — the controller reads the
  # release point off the terminal event itself. `dx`/`dy` may also be given
  # in px (any magnitude > 1 is taken literally).
  def swipe_top_card(dx: 0, dy: 0, terminal: "pointerup")
    execute_script(<<~JS)
      (() => {
        const stack = document.querySelector('.preview-card.active .rotate-card-stack')
        const cards = [...stack.querySelectorAll('.rotate-card')]
        const top   = cards.find((c) => c.style.opacity !== '0')
        const s  = stack.getBoundingClientRect()
        const px = (v, size) => Math.abs(v) > 1 ? v : v * size
        const x0 = s.left + s.width / 2, y0 = s.top + s.height / 2
        const x1 = x0 + px(#{dx}, s.width), y1 = y0 + px(#{dy}, s.height)
        const base = { bubbles: true, cancelable: true, pointerId: 7, pointerType: 'touch' }
        top.dispatchEvent(new PointerEvent('pointerdown',
          Object.assign({}, base, { clientX: x0, clientY: y0 })))
        window.dispatchEvent(new PointerEvent('pointermove',
          Object.assign({}, base, { clientX: x1, clientY: y1 })))
        window.dispatchEvent(new PointerEvent('#{terminal}',
          Object.assign({}, base, { clientX: x1, clientY: y1 })))
      })()
    JS
  end

  test "the card opts out of browser touch panning so the swipe is ours" do
    open_tap_card
    assert_equal "none", evaluate_script(
      "getComputedStyle(document.querySelector('.preview-card.active .rotate-card')).touchAction"
    ), "without touch-action: none the browser reads a horizontal pull as history navigation"
  end

  test "a right swipe answers yes and surfaces the next card" do
    open_tap_card
    first = top_card_statement

    swipe_top_card(dx: 0.35)
    assert_equal "yes", results[first], "a right swipe past threshold must record yes"
    assert_not_equal first, top_card_statement, "the answered card must leave the top"
  end

  test "an up swipe answers unsure" do
    open_tap_card
    first = top_card_statement

    swipe_top_card(dy: -0.30)
    assert_equal "unsure", results[first]
  end

  test "a sub-threshold drag snaps back and records nothing" do
    open_tap_card
    first = top_card_statement

    # 18px: under the flick minimum (24px) and nowhere near the distance
    # threshold — synthetic events are near-instant, so anything past the
    # flick minimum would legitimately commit as a flick.
    swipe_top_card(dx: 18)
    assert_empty results, "a drag released short of every threshold is not an answer"
    assert_equal first, top_card_statement, "the card must snap back to the top"
  end

  test "a cancelled drag restores the card and arms nothing" do
    open_tap_card
    first = top_card_statement

    swipe_top_card(dx: 0.35, terminal: "pointercancel")
    assert_empty results, "a browser-claimed gesture is not an answer"
    assert_equal first, top_card_statement

    # A later stray pointerup must find no armed drag to commit.
    execute_script("window.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerId: 9, clientX: 900, clientY: 300 }))")
    assert_empty results
  end

  test "the buttons still answer" do
    open_tap_card
    first = top_card_statement

    find(".preview-card.active .rotate-action-no").click
    assert_equal "no", results[first], "the tap path must survive the swipe refactor"
  end

  test "an exhausted deck shows the all-answered face until reset" do
    open_tap_card
    assert_selector ".preview-card.active .rotate-complete", visible: :hidden

    3.times { swipe_top_card(dx: 0.35) }

    assert_selector ".preview-card.active .rotate-wrap.is-complete", wait: 3
    assert_selector ".preview-card.active .rotate-complete", visible: :visible, wait: 3
    assert_equal "none", evaluate_script(
      "getComputedStyle(document.querySelector('.preview-card.active .rotate-card-controls')).pointerEvents"
    ), "the dead buttons must stop swallowing taps"

    click_button "↺ Reset"
    assert_no_selector ".preview-card.active .rotate-wrap.is-complete", wait: 3
    assert_empty results, "reset must clear the recorded swipes"
  end
end
