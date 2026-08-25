require "application_system_test_case"

# The survey-level consent gate used to be a full-screen card pinned in front
# of the deck. It is a bottom banner now — "so we are straight into the verto
# and not needing a card beforehand" — which trades one invariant for another:
# the first QUESTION is on screen from the first paint, so what has to be
# guaranteed is that nothing about it works until a choice is made. The
# overlay's data-consent-pending attribute owns that state: the deck is inert
# and dimmed, the footer nav is hidden, and the banner is the only live
# surface. Agreeing hands the deck back; declining swaps the banner's message
# in place and hands nothing back.
class PlayerConsentBannerTest < ApplicationSystemTestCase
  PHONE   = [ 393, 852 ].freeze
  DESKTOP = [ 1280, 900 ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "pcb2-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Banner", theme: "T", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      consent_text: "Your anonymous answers may be used for research.",
      cards: [
        { "type" => "multiple_choice", "cid" => "q1", "text" => "First question?",
          "options" => [ "Yes", "No", "Maybe" ] },
        { "type" => "yes_no", "cid" => "q2", "text" => "Second question?" }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: DESKTOP[0], height: DESKTOP[1])
    super
  end

  def open_player(width: DESKTOP[0], height: DESKTOP[1])
    page.driver.browser.resize(width: width, height: height)
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    assert_selector ".play-consent-banner", wait: 5
  end

  def pending?
    page.evaluate_script("document.querySelector('.preview-overlay').hasAttribute('data-consent-pending')")
  end

  test "the first question is on screen behind the banner, inert until agreed" do
    open_player
    assert pending?, "the overlay should render consent-pending"
    # The question card is the ACTIVE card — no card stands in front of it.
    assert_equal "multiple_choice", find(".preview-card.active")["data-card-type"]
    assert find(".preview-card.active")["data-card-index"],
           "the first deck card carries a real index — no pseudo-card eats position 0"
    # The deck is inert: a REAL tap on an option must not select it. (A
    # synthetic el.click() would sail through — inert guards trusted events,
    # which is the only kind a respondent can produce.)
    attempt_real_click_on_option
    assert_no_selector ".preview-card.active [data-selected='true']"
    # And the deck nav is out of reach while the banner decides.
    assert_no_selector ".preview-btn-next", visible: true
    assert_no_selector ".preview-progress-text", visible: true
  end

  # A trusted click at the option's coordinates. Under `inert` the hit test
  # skips the whole deck, which some drivers surface as a "click intercepted"
  # error — that error IS the guarantee working, so it is swallowed.
  def attempt_real_click_on_option
    first(".preview-card.active .choice-list-item").click
  rescue StandardError
    nil
  ensure
    sleep 0.3
  end

  test "agreeing dismisses the banner and hands the deck back" do
    open_player
    click_button "Agree & continue"
    sleep 0.4
    assert_not pending?, "agreeing should clear the pending state"
    assert_no_selector ".play-consent-banner", visible: true
    assert_selector ".preview-btn-next", visible: true
    assert_selector ".preview-progress-text", visible: true, text: /1/
    first(".preview-card.active .choice-list-item").click
    sleep 0.3
    # After agreeing the question must be answerable.
    assert_selector ".preview-card.active [data-selected='true']"
  end

  test "declining swaps the message in place and the deck stays inert" do
    open_player
    click_button "I don't agree"
    sleep 0.4
    assert_selector ".play-consent-declined", visible: true
    assert_no_selector ".play-consent-agree", visible: true
    assert pending?, "declining is terminal — the deck never unlocks"
    attempt_real_click_on_option
    assert_no_selector ".preview-card.active [data-selected='true']"
  end

  test "focus lands in the banner, and Escape does not dismiss it" do
    open_player
    # Dismissing the cookie banner steals focus on a first visit — for the
    # cookie banner's own keyboard users, rightly. A revisit remembers the
    # dismissal, so the consent banner's connect()-time focus stands.
    visit "/play/#{@survey.publish_token}"
    assert_selector ".play-consent-banner", wait: 5
    sleep 0.3
    focused = page.evaluate_script("document.activeElement?.classList?.contains('play-consent-banner')")
    assert focused, "keyboard users should start in the dialog that blocks everything else"
    find(".play-consent-banner").send_keys(:escape)
    sleep 0.2
    assert pending?, "consent is a choice, not a dismissable popup"
    assert_selector ".play-consent-banner", visible: true
  end

  test "the banner works on a phone with stacked buttons" do
    open_player(width: PHONE[0], height: PHONE[1])
    assert pending?
    click_button "Agree & continue"
    sleep 0.4
    assert_not pending?
    assert_selector ".preview-card.active", visible: true
  end

  test "the respondent-code gate still follows the banner where enabled" do
    @survey.update_columns(respondent_code_enabled: true)
    open_player
    # The code gate is a leading index-less card UNDER the banner, so the
    # respondent meets it the moment they agree.
    assert_equal "respondent_code_card", find(".preview-card.active")["data-card-type"]
    click_button "Agree & continue"
    sleep 0.4
    assert_selector ".respondent-code-input", visible: true
    find(".respondent-code-input").set("team-7")
    click_button I18n.t("player.respondent_code_continue")
    sleep 0.4
    assert_equal "multiple_choice", find(".preview-card.active")["data-card-type"]
  end
end
