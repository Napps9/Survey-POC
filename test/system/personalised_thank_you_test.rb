require "application_system_test_case"

# Template variables in the thank-you title/body are interpolated client-side
# in player_controller.js#_applyEndScreen.
#
# This used to pin both directions of %{name}, read off an answered contact
# card. That card type is retired, so nothing asks a respondent their name any
# more and %{name} is gone from _endScreenVars — which makes the surviving
# direction the important one: thank-you copy WRITTEN BEFORE the retirement
# still says "%{name|friend}", and it has to render "friend". A variable that
# no longer exists must take its inline fallback, or be stripped where there
# isn't one — never leave a raw %{name} on screen in front of a respondent.
class PersonalisedThankYouTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "open_ended", "cid" => "c1", "text" => "Anything else?" }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "ty-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Personalised", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS,
                                   thankyou_title: "Thanks, %{name|friend}!",
                                   thankyou_body: "See you soon, %{name|there}. %{name}")
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def play_to_the_end
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # past the welcome card
    assert_selector ".preview-card.active .freeform-wrap", wait: 5
    find("[data-player-target='finishBtn']").click
  end

  test "a retired variable takes its inline fallback, and is stripped without one" do
    play_to_the_end

    assert_selector ".preview-thankyou-title", text: "Thanks, friend!", wait: 5
    assert_text "See you soon, there."
    assert_no_text "%{name"
  end
end
