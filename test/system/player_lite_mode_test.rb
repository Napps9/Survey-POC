require "application_system_test_case"

# The respondent-side data-saving toggle. Modelled on forms mode for the
# motion side (application.css extends every .forms-mode rule to also match
# .lite-mode) and on player_shed_order_test's own debt model for the
# "never buy artwork back" side — see player_controller.js#toggleLite/_fitCard.
class PlayerLiteModeTest < ApplicationSystemTestCase
  ROOMY = [ 1024, 1290 ].freeze # plenty of room — a non-lite card would show its hero

  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "multiple_choice", "text" => "Pick one", "image" => "/nope.jpg", "options" => %w[a b c] }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "lite-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Lite", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS)
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def teardown
    page.driver.browser.resize(width: 1280, height: 900)
    super
  end

  def open_player
    page.driver.browser.resize(width: ROOMY[0], height: ROOMY[1])
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
  end

  def has_class?(selector, klass)
    find(selector)["class"].to_s.split.include?(klass)
  end

  test "toggling lite mode marks the overlay and the button, and reverses on a second tap" do
    open_player
    refute has_class?(".preview-overlay", "lite-mode")
    assert_equal "false", find(".lite-mode-btn")["aria-pressed"]

    find(".lite-mode-btn").click
    assert has_class?(".preview-overlay", "lite-mode")
    assert_equal "true", find(".lite-mode-btn")["aria-pressed"]

    find(".lite-mode-btn").click
    refute has_class?(".preview-overlay", "lite-mode")
    assert_equal "false", find(".lite-mode-btn")["aria-pressed"]
  end

  test "lite mode never buys the hero back, even with plenty of room" do
    open_player
    click_button "Next" # onto the image question
    sleep 0.4 # _fitCard's re-measure

    refute has_class?(".preview-card.active", "hero-off"),
           "a roomy viewport should show the hero when lite is off"

    find(".lite-mode-btn").click
    sleep 0.4

    assert has_class?(".preview-card.active", "hero-off"),
           "lite mode must pin the card to its floor even where there'd be room"
  end

  test "a fresh card entry carries no motion animation class while lite is on" do
    open_player
    find(".lite-mode-btn").click

    click_button "Next"
    # Checked immediately, not after a settle — is-entering is added
    # synchronously if it's going to be added at all (then removed on
    # animationend ~0.26s later), so a delayed check can't tell "never added"
    # from "already finished" apart.
    refute has_class?(".preview-card.active", "is-entering")
  end

  test "without lite mode, the same entry DOES carry the animation class — proving the check means something" do
    open_player
    click_button "Next"
    assert has_class?(".preview-card.active", "is-entering")
  end

  test "the choice persists across a fresh visit" do
    open_player
    find(".lite-mode-btn").click
    assert_equal "1", evaluate_script("localStorage.getItem('verto_lite_mode')")

    visit "/play/#{@survey.publish_token}"
    assert has_class?(".preview-overlay", "lite-mode")
    assert_equal "true", find(".lite-mode-btn")["aria-pressed"]
  end
end
