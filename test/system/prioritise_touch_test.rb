require "application_system_test_case"

# Drag-to-rank on touch. The type's core gesture never worked on phones:
# touch-action: pan-y let the browser claim every vertical touch-drag as a
# scroll (firing pointercancel), and the controller had no pointercancel
# handler — so the row stuck mid-air in .is-dragging and the still-armed
# window pointerup committed a spurious reorder on the next tap anywhere.
#
# Cuprite has no touch synthesis, so the pointer sequences are dispatched as
# synthetic PointerEvents. That is faithful here: the controller listens for
# exactly these events on exactly these targets (row pointerdown, window
# move/up/cancel), and the pan-y half of the bug is pinned separately by
# asserting the computed touch-action, which is what decides whether a real
# browser ever lets the sequence reach the controller.
class PrioritiseTouchTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "prioritise", "cid" => "c1", "text" => "Rank these",
      "options" => %w[Water Food Shelter Wifi] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "drag-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Drag", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def open_prioritise_card
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # past the welcome card
    assert_selector ".preview-card.active .prioritise-item", count: 4, wait: 5
  end

  # The player shuffles the authored order, so every assertion is relative to
  # what actually rendered, never to CARDS.
  def row_labels
    evaluate_script(<<~JS)
      [...document.querySelectorAll('.preview-card.active .prioritise-item .choice-list-label')]
        .map((el) => el.textContent.trim())
    JS
  end

  def touched?
    evaluate_script(
      "document.querySelector('.preview-card.active .prioritise-list')?.dataset?.prioritiseTouched === 'true'"
    )
  end

  # Presses row 0 and drags it down `steps` row-heights, ending the gesture
  # with `terminal` ("pointerup" commits, "pointercancel" abandons).
  def drag_first_row(steps:, terminal:)
    execute_script(<<~JS)
      const rows = document.querySelectorAll('.preview-card.active .prioritise-item')
      const row  = rows[0]
      const a    = row.getBoundingClientRect()
      const step = rows[1].getBoundingClientRect().top - a.top
      const base = { bubbles: true, cancelable: true, pointerId: 7, pointerType: 'touch',
                     clientX: a.left + a.width / 2, clientY: a.top + a.height / 2 }
      row.dispatchEvent(new PointerEvent('pointerdown', base))
      window.dispatchEvent(new PointerEvent('pointermove',
        Object.assign({}, base, { clientY: base.clientY + step * #{steps} })))
      window.dispatchEvent(new PointerEvent('#{terminal}', base))
    JS
  end

  test "rows opt out of browser touch panning so the drag is ours" do
    open_prioritise_card
    assert_equal "none", evaluate_script(
      "getComputedStyle(document.querySelector('.preview-card.active .prioritise-item')).touchAction"
    ), "pan-y here hands the vertical drag to the scroller and the gesture dies as pointercancel"
  end

  test "a touch drag reorders the rows" do
    open_prioritise_card
    before = row_labels

    drag_first_row(steps: 1, terminal: "pointerup")
    assert_no_selector ".prioritise-item.is-dragging", wait: 3 # commit is animated

    expected = [ before[1], before[0], before[2], before[3] ]
    assert_equal expected, row_labels, "one step down must swap the first two rows"
    assert touched?, "a committed reorder is an answer"
  end

  test "a cancelled drag restores the order and arms nothing" do
    open_prioritise_card
    before = row_labels

    drag_first_row(steps: 1, terminal: "pointercancel")

    assert_no_selector ".prioritise-item.is-dragging", wait: 3
    assert_equal before, row_labels, "an abandoned gesture must put the row back"
    assert_not touched?, "an abandoned gesture is not an answer"

    # The historical failure: cancel left the window pointerup armed, so the
    # NEXT tap anywhere committed the half-made reorder.
    execute_script("window.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerId: 9 }))")
    assert_equal before, row_labels, "a tap after a cancelled drag must not replay the reorder"
    assert_not touched?
  end
end
