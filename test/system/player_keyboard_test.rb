require "application_system_test_case"

# The behaviour P2-4 fixed, pinned in a real browser instead of by asserting on
# source text. Everything here was verified by hand while that work was done;
# this is what stops it regressing silently.
#
# It matters more than most browser tests would: the failure mode isn't a
# cosmetic glitch, it's a respondent who cannot answer the question at all.
class PlayerKeyboardTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "multiple_choice", "cid" => "c1", "text" => "Which colour?",
      "options" => %w[Red Blue Green] },
    { "type" => "rating", "cid" => "c2", "text" => "Rate it", "options" => [ "Poor", "Great" ] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "sys-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Keyboard", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  # Cuprite's Element#send_keys CLICKS the element to focus it first, which
  # fires the click handler and makes a "keyboard only" assertion pass even
  # with the key binding removed — verified by disabling picker#pickOnKey and
  # watching these tests stay green. So focus is set through the DOM and the
  # key is delivered to whatever is focused, with no pointer involved at all.
  def focus_via_dom(selector, index: 0)
    execute_script("document.querySelectorAll(#{selector.to_json})[#{index}].focus()")
  end

  # Ferrum takes its own aliases here (:left, not :ArrowLeft — a symbol is
  # downcased and looked up in KEYS_MAPPING, so the DOM name misses).
  def press(key)
    page.driver.browser.keyboard.type(key)
  end

  def open_player
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    # Every Verto collects the demographic tail, so P0-6's default consent gate
    # stands in front of the deck.
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  test "a choice option can be selected with the keyboard alone" do
    open_player
    click_button "Next"   # past the welcome card

    option = find('.preview-card.active li[role="radio"]', match: :first)
    assert_equal "false", option["aria-checked"]

    focus_via_dom('.preview-card.active li[role="radio"]')
    press(:Enter)

    assert_equal "true", option["aria-checked"]
    assert_equal "true", option["data-selected"], "the answer must actually be captured, not just announced"
  end

  test "space selects and does not scroll the page away" do
    open_player
    click_button "Next"

    options = all('.preview-card.active li[role="radio"]')
    focus_via_dom('.preview-card.active li[role="radio"]', index: 1)
    press(:Space)

    assert_equal "true",  options[1]["aria-checked"]
    assert_equal "false", options[0]["aria-checked"], "single-select must move, not accumulate"
  end

  test "the option set is announced as a radiogroup" do
    open_player
    click_button "Next"
    assert_selector '.preview-card.active ul[role="radiogroup"]'
    assert_selector '.preview-card.active li[role="radio"]', count: 3
  end

  test "focus follows the deck when the card changes" do
    # Without this the rest is only half useful: every control is operable, but
    # advancing strands focus on a hidden element and the respondent has to Tab
    # from the top of the document on every question.
    open_player
    before = evaluate_script("document.activeElement === document.querySelector('.preview-card.active')")
    click_button "Next"

    assert_selector ".preview-card.active", wait: 5
    focused_active = evaluate_script(
      "document.activeElement === document.querySelector('.preview-card.active')"
    )
    assert focused_active, "focus should land on the card that just appeared (was #{before} before)"
  end

  test "focus is not stolen on first load" do
    # Taking focus on page load is disorienting and moves it away from anything
    # the browser restored.
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    tag = evaluate_script("document.activeElement && document.activeElement.tagName")
    assert_equal "BODY", tag
  end

  test "the active card is focusable without joining the tab order" do
    open_player
    click_button "Next"
    assert_equal "-1", find(".preview-card.active")["tabindex"],
                 "Tab must still walk the card's own controls, not the wrapper"
  end

  test "rating stars are keyboard operable and individually labelled" do
    open_player
    click_button "Next"
    focus_via_dom('.preview-card.active li[role="radio"]')
    press(:Enter)
    click_button "Next"

    stars = all('.preview-card.active .rating-star[role="radio"]')
    assert_equal 5, stars.size
    assert_equal "3 of 5", stars[2]["aria-label"]

    focus_via_dom('.preview-card.active .rating-star[role="radio"]', index: 3)
    press(:Enter)
    assert_equal "true", stars[3]["aria-checked"]

    focus_via_dom('.preview-card.active .rating-star[role="radio"]', index: 3)
    press(:left)
    assert_equal "true",  stars[2]["aria-checked"]
    assert_equal "false", stars[3]["aria-checked"]
  end
end
