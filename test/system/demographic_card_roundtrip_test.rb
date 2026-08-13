require "application_system_test_case"

# The one regression only a real browser can catch: serialize() rebuilds every
# card from the DOM, so if either the _card_row data attribute or the
# serialize() emission for demographic_key goes missing, the FIRST autosave
# after inserting an opt-in demographic card silently strips the key — the
# card degrades to an unkeyed demographic multiple_choice that then collides
# with the gender finder. This drives the real tile → insert → autosave →
# reload loop.
class DemographicCardRoundtripTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "dg-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Dg", email_address: "dg-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Demo", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: [
                                     { "type" => "welcome_card", "title" => "Hello" },
                                     { "type" => "yes_no", "cid" => "q1", "text" => "First?",
                                       "options" => %w[Yes No] }
                                   ])
  end

  test "an inserted heritage card keeps its key and options through autosave" do
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "First?"

    # Open the add-question modal and click the Heritage tile.
    first("[data-action='click->add-question#open']", visible: :all).click
    assert_selector "[data-demographic-key='heritage']"
    find("[data-demographic-key='heritage']").click

    # The card lands at the end of the deck, key attribute in place.
    assert_selector "[data-card-demographic-key='heritage']", wait: 10
    assert_text "Which of these best reflects your heritage?"

    # Force an unrelated edit so serialize() rebuilds every card, then wait
    # for the autosave to persist.
    find("[data-card-cid='q1'] .q-title").click
    execute_script(<<~JS)
      const el = document.querySelector("[data-card-cid='q1'] .q-title")
      el.textContent = "First question?"
      el.dispatchEvent(new Event("input", { bubbles: true }))
    JS
    Timeout.timeout(15) do
      sleep 0.25 until @survey.reload.cards.any? { |c| c["demographic_key"] == "heritage" } &&
                       @survey.cards.find { |c| c["cid"] == "q1" }["text"] == "First question?"
    end

    card = @survey.cards.last
    assert_equal "heritage", card["demographic_key"],
                 "the key must survive the DOM round trip — without it the card " \
                 "collides with the gender finder"
    assert card["demographic"]
    assert_equal 8, card["options"].size, "the taxonomy options must survive too"

    # And the tile is greyed out on the next open.
    visit survey_path(@survey)
    dismiss_cookie_banner
    first("[data-action='click->add-question#open']", visible: :all).click
    assert_selector "[data-demographic-key='heritage'][disabled]"
  end

  # Same round trip, one field further on. A tailored card carries
  # heritage_country, which nothing in the editor displays — so a missing
  # _card_row attribute or serialize() line strips it on the first autosave and
  # the Verto forgets its Heritage card was ever built for a country. Starts
  # from a deck that already has the card rather than driving the tile: the
  # DOM round trip is what's under test, and stubbing an AI service across the
  # in-process Puma thread is the fragile part of this suite.
  test "a tailored heritage card keeps its country, Other box and options through autosave" do
    five = [ "White British", "Indian", "Pakistani", "Black Caribbean", "Chinese" ]
    @survey.update!(
      audience_country: "GB",
      cards: @survey.cards + [ DemographicQuestions.country_heritage_card(country: "GB", five: five) ]
    )

    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "First?"
    assert_selector "[data-card-heritage-country='GB']"

    find("[data-card-cid='q1'] .q-title").click
    execute_script(<<~JS)
      const el = document.querySelector("[data-card-cid='q1'] .q-title")
      el.textContent = "First question?"
      el.dispatchEvent(new Event("input", { bubbles: true }))
    JS
    Timeout.timeout(15) do
      sleep 0.25 until @survey.reload.cards.find { |c| c["cid"] == "q1" }["text"] == "First question?"
    end

    card = @survey.cards.last
    assert_equal "GB", card["heritage_country"],
                 "without this the Verto forgets which country's taxonomy it is asking in"
    assert card["allow_other"], "the free-text Other box must survive too"
    assert_equal five + [ DemographicQuestions.heritage_decline_option ], card["options"]
  end
end
