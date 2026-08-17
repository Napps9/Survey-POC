require "application_system_test_case"

# %{name} (and friends) in the thank-you title/body is interpolated
# client-side in player_controller.js#_applyEndScreen, from whichever
# contact_form card's name field the respondent actually answered. This pins
# both directions: filled in, and left blank — where the inline fallback (or
# a plain strip to "" without one) has to take over, never a raw %{name} left
# on screen.
class PersonalisedThankYouTest < ApplicationSystemTestCase
  CARDS = [
    { "type" => "welcome_card", "title" => "Welcome" },
    { "type" => "contact_form", "cid" => "c1", "text" => "Stay in touch" }
  ].freeze

  def setup
    super
    @org    = Organisation.create!(name: "O", slug: "ty-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(title: "Personalised", theme: "Th", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: CARDS,
                                   thankyou_title: "Thanks, %{name|friend}!",
                                   thankyou_body: "See you soon, %{name|there}.")
    @survey.update_columns(publish_token: SecureRandom.hex(8), published_at: Time.current)
  end

  def open_contact_card
    visit "/play/#{@survey.publish_token}"
    dismiss_cookie_banner
    click_button "Agree & continue" if has_button?("Agree & continue", wait: 3)
    click_button "Next" # past the welcome card
    assert_selector ".preview-card.active .contact-form-wrap", wait: 5
  end

  test "an answered name interpolates into the thank-you copy" do
    open_contact_card
    find(".contact-field[data-contact-key='name']").set("Alex")
    find("[data-player-target='finishBtn']").click

    assert_selector ".preview-thankyou-title", text: "Thanks, Alex!", wait: 5
    assert_text "See you soon, Alex."
  end

  test "a skipped contact card falls back to the inline default, never a raw placeholder" do
    open_contact_card
    find("[data-player-target='finishBtn']").click

    assert_selector ".preview-thankyou-title", text: "Thanks, friend!", wait: 5
    assert_text "See you soon, there."
    assert_no_text "%{name"
  end
end
