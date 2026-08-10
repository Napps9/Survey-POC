require "application_system_test_case"

# The scenario book hides non-current pages with opacity/pointer-events inline
# styles only — a visual stack. Without inert + aria-hidden every page stayed
# in the accessibility tree and tab order at once, so a screen reader heard
# the whole story plus the answers on arrival, and Tab walked through
# invisible pages. These pin the fix where it lives: layout() re-stamps the
# attributes on every turn, in a real browser.
class ScenarioPlayerAriaTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "scenario", "cid" => "sc1", "text" => "What would you do?",
      "pages" => [ { "id" => "pg1", "text" => "Your laptop dies." },
                   { "id" => "pg2", "text" => "A new one costs $600." } ],
      "options" => [ "Use savings", "Use credit" ] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "aria-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Book", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def open_book
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # past the welcome card
    assert_selector ".preview-card.active .book-page", count: 3, wait: 5 # 2 narrative + answer
  end

  # [{ inert:, hidden: }] in DOM order: pg1, pg2, answer page.
  def page_states
    evaluate_script(<<~JS)
      [...document.querySelectorAll('.preview-card.active .book-page')]
        .map((p) => ({ inert: p.hasAttribute('inert'), hidden: p.getAttribute('aria-hidden') }))
    JS
  end

  def turn_page
    find('.preview-card.active .book-chevron[aria-label="Next page"]').click
  end

  test "only the current page is exposed, and a turn moves the exposure" do
    open_book

    states = page_states
    assert_equal [ false, true, true ], states.map { |s| s["inert"] }
    assert_equal [ "false", "true", "true" ], states.map { |s| s["hidden"] }

    turn_page
    assert_equal [ true, false, true ], page_states.map { |s| s["inert"] },
      "after one turn, page 2 is current and BOTH neighbours — including the turned page — are out"

    turn_page
    assert_equal [ true, true, false ], page_states.map { |s| s["inert"] },
      "at the answer page the whole story is out of the tree"
  end

  test "inert actually blocks focus into a page that is not open" do
    # The attribute alone can be asserted from source; that it WORKS cannot.
    # inert makes descendants unfocusable, so the answer radios must refuse
    # focus while the story is open — the tab-order leak this fix closes.
    open_book

    landed = evaluate_script(<<~JS)
      (() => {
        const radio = document.querySelector('.preview-card.active .book-page.is-answer li[role="radio"]')
        radio.focus()
        return document.activeElement === radio
      })()
    JS
    assert_not landed, "a radio on the closed answer page accepted focus — inert is not holding"

    turn_page # to page 2
    turn_page # to the answer page
    landed = evaluate_script(<<~JS)
      (() => {
        const radio = document.querySelector('.preview-card.active .book-page.is-answer li[role="radio"]')
        radio.focus()
        return document.activeElement === radio
      })()
    JS
    assert landed, "on the open answer page the same radio must accept focus"
  end
end
