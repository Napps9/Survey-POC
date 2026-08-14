require "application_system_test_case"

# The right-hand editor panel used to re-point on click alone, so a creator could
# scroll from card 2 down to card 7 and then change the answer type of card 2 —
# off screen, and not what they were looking at. editor-scroll-sync fixes that by
# following the feed, which scroll-snaps one card to its centre at a time.
#
# All of it is browser behaviour: an IntersectionObserver on a real scroller, a
# settle timer, and guards keyed off focus and a CSS class. Only Chrome can say
# whether the panel actually moves.
class EditorScrollSyncTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Hello" },
    { "type" => "yes_no",          "cid" => "c1", "text" => "First question?",  "options" => %w[Yes No] },
    { "type" => "yes_no",          "cid" => "c2", "text" => "Second question?", "options" => %w[Yes No] },
    { "type" => "multiple_choice", "cid" => "c3", "text" => "Third question?",  "options" => %w[A B C] },
    { "type" => "yes_no",          "cid" => "c4", "text" => "Fourth question?", "options" => %w[Yes No] }
  ].freeze

  def setup
    super
    @org  = Organisation.create!(name: "Sync", slug: "sy-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Sy", email_address: "sy-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")
  end

  def create_survey(**extra)
    @org.surveys.create!(title: "Sync", theme: "Safety", audience_age: "adults",
                         key_insight: "k", default_locale: "en", locales: [ "en" ],
                         cards: CARDS, **extra)
  end

  def open_editor(survey)
    sign_in_as(@user)
    visit survey_path(survey)
    dismiss_cookie_banner
    assert_text "Fourth question?"
  end

  # Instant, not smooth: a smooth scroll is still travelling when the assertions
  # start, and it drags the centre line across every card on the way. Capybara's
  # retrying matchers absorb the controller's 140ms settle timer on their own.
  def scroll_to(selector)
    execute_script(<<~JS)
      document.querySelector("#{selector}")
              .scrollIntoView({ block: "center", behavior: "instant" })
    JS
  end

  def panel_card_name
    find("[data-type-panel-target='panelCardName']").text
  end

  # Selecting through the card's number pill rather than the card body: the pill
  # has no handler of its own so the click bubbles to type-panel#selectCard,
  # whereas a click mid-card can land on the media prompt instead.
  def select_card(cid)
    find("[data-card-cid='#{cid}'] .card-num-pill").click
    assert_selector ".editor-grid.is-panel-open"
    assert_selector "[data-card-cid='#{cid}'].selected"
  end

  # type-panel's activeCardEl, not the .selected class: it's what the panel's
  # Required / Allow-other switches and every type change actually act on, so
  # it's the thing that was pointing at the wrong card.
  def active_card_cid
    evaluate_script(<<~JS)
      (window.Stimulus || window.application).getControllerForElementAndIdentifier(
        document.querySelector('[data-controller~="type-panel"]'), "type-panel"
      ).activeCardEl?.dataset?.cardCid
    JS
  end

  test "scrolling the feed re-points the open panel at the centred card" do
    open_editor(create_survey)

    select_card("c1")
    assert_equal "Card 2 · YES / NO", panel_card_name,
                 "the panel should name the clicked card (the welcome card is card 1)"

    # c3 is a different answer type, so this proves the panel repaints its
    # contents for the new card rather than only re-labelling the heading.
    scroll_to("[data-card-cid='c3']")

    # The card at the centre takes the selection, and the one scrolled away from
    # gives it up.
    assert_selector "[data-card-cid='c3'].selected"
    assert_no_selector "[data-card-cid='c1'].selected"
    assert_equal "Card 4 · PICK ONE", panel_card_name,
                 "the panel heading must follow the scroll, or the creator still " \
                 "can't tell which card they're about to change"
    assert_equal "c3", active_card_cid

    # Scrolling back moves it back — the sync isn't one-way.
    scroll_to("[data-card-cid='c1']")
    assert_selector "[data-card-cid='c1'].selected"
    assert_equal "Card 2 · YES / NO", panel_card_name
    assert_equal "c1", active_card_cid
  end

  test "scrolling never opens a collapsed panel or selects a first card" do
    open_editor(create_survey)

    assert_no_selector ".editor-grid.is-panel-open"
    scroll_to("[data-card-cid='c4']")

    # A negative with a real wait: if the sync were ungated this would have fired
    # several times over within the second. Scrolling must not be what OPENS the
    # panel — the editor opens with it collapsed and the cards centred like the
    # player — and with nothing selected there's no wrong card to correct, so a
    # scroll must not pick one either.
    assert_no_selector ".editor-grid.is-panel-open", wait: 1
    assert_no_selector ".survey-card-wrap.selected", wait: 0
  end

  test "scrolling onto the thank-you screen leaves the last card selected" do
    open_editor(create_survey(thankyou_title: "Thanks!", thankyou_body: "All done."))

    select_card("c4")
    scroll_to("[data-gate-cards-target='tyCard']")

    # The thank-you screen is a snap target but not a card — it's edited in the
    # feed, so the panel must hold the last card it can actually edit rather than
    # blanking out under something it has no controls for.
    assert_selector "[data-card-cid='c4'].selected", wait: 1
    assert_equal "c4", active_card_cid
  end

  test "a re-point waits for focus to leave the panel" do
    open_editor(create_survey)

    select_card("c1")
    # Standing in the panel: it holds DOM blocks moved out of the selected card,
    # so re-pointing now would move a focused node mid-keystroke.
    execute_script("document.querySelector('.right-tab-close').focus()")

    # A scroll must not re-point the panel out from under someone working in it.
    scroll_to("[data-card-cid='c4']")
    assert_no_selector "[data-card-cid='c4'].selected", wait: 1
    assert_selector "[data-card-cid='c1'].selected"

    # Once focus leaves the panel the held-back re-point must land, or the panel
    # stays on the old card for good.
    execute_script("document.activeElement.blur()")
    assert_selector "[data-card-cid='c4'].selected"
    assert_equal "c4", active_card_cid
  end
end
