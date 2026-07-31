require "application_system_test_case"

# BUG-030. `#generate_card` runs `translate_card!`, which bills one Claude call
# per secondary locale, and then returned `{ ok: true, html: }` — the i18n map
# computed and thrown away.
#
# The editor could not have recovered it either: `_seedStore()` reads a JSON
# blob rendered into the page, so it only ever knows the deck as it was at page
# load. A card added afterwards had no store entry, `_captureLocale` filled one
# from the DOM for the language on screen, and the next autosave wrote the card
# back monolingual. The translations were paid for and discarded within seconds.
#
# The store is client state, so a browser is the only place this is visible.
class GeneratedCardTranslationsTest < ApplicationSystemTestCase
  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "gt-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Gt", email_address: "gt-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(
      title: "Multi", theme: "Safety", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: %w[en fr],
      cards: [ { "type" => "welcome_card", "title" => "Hello" },
               { "type" => "yes_no", "cid" => "q1", "text" => "Do you feel safe?",
                 "options" => %w[Yes No],
                 "i18n" => { "fr" => { "text" => "Vous sentez-vous en sécurité ?",
                                       "options" => %w[Oui Non] } } } ]
    )
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_text "Do you feel safe?"
  end

  # Insert a card the way a generate response does — HTML plus its card JSON,
  # translations and all. Stubbing Claude through a live server thread would
  # test the stub; this drives the exact seam the bug was in.
  def insert_generated_card
    execute_script(<<~JS)
      const app  = window.Stimulus || window.application
      const root = document.querySelector('[data-controller~="add-question"]')
      const aq   = app.getControllerForElementAndIdentifier(root, "add-question")
      const wrap = document.querySelector("[data-card-cid='q1']").closest(".card-slot")
      aq._insertAfterSlot = wrap
      aq._insertHTML(
        document.querySelector("[data-card-cid='q1']").outerHTML
          .replace('data-card-cid="q1"', 'data-card-cid="gen1"')
          .replace("Do you feel safe?", "Is your street well lit?"),
        { type: "yes_no", cid: "gen1", text: "Is your street well lit?",
          options: ["Yes", "No"],
          i18n: { fr: { text: "Votre rue est-elle bien éclairée ?", options: ["Oui", "Non"] } } }
      )
    JS
  end

  def stored_card(cid)
    @survey.reload.cards.find { |c| c["cid"] == cid }
  end

  test "a generated card keeps its translations through the next autosave" do
    open_editor
    insert_generated_card

    # Any edit triggers the autosave that rebuilds the whole deck.
    execute_script(<<~JS)
      const q = document.querySelector("[data-card-cid='q1'] .q-title")
      q.textContent = "Do you feel safe here?"
      q.dispatchEvent(new Event("input", { bubbles: true }))
      q.blur()
    JS

    Timeout.timeout(15) do
      sleep 0.25 until @survey.reload.cards.any? { |c| c["cid"] == "gen1" }
    end

    card = stored_card("gen1")
    assert_equal "Votre rue est-elle bien éclairée ?", card.dig("i18n", "fr", "text"),
                 "the translation the server paid Claude for was discarded on the first save"
    assert_equal %w[Oui Non], card.dig("i18n", "fr", "options")
  end

  # The existing deck must be unaffected — seeding a new entry must not disturb
  # the entries seeded at page load.
  test "the deck's existing translations are untouched" do
    open_editor
    insert_generated_card

    execute_script(<<~JS)
      const q = document.querySelector("[data-card-cid='q1'] .q-title")
      q.textContent = "Do you feel safe here?"
      q.dispatchEvent(new Event("input", { bubbles: true }))
      q.blur()
    JS

    Timeout.timeout(15) do
      sleep 0.25 until @survey.reload.cards.any? { |c| c["text"].to_s.include?("safe here") }
    end

    assert_equal "Vous sentez-vous en sécurité ?", stored_card("q1").dig("i18n", "fr", "text")
  end

  # A card inserted with no JSON (the blank "start from blank" path, which has
  # nothing to translate) must still work rather than throw.
  test "a card inserted without JSON is still inserted" do
    open_editor
    before = all("[data-survey-editor-target='card']").size

    execute_script(<<~JS)
      const app  = window.Stimulus || window.application
      const root = document.querySelector('[data-controller~="add-question"]')
      const aq   = app.getControllerForElementAndIdentifier(root, "add-question")
      aq._insertHTML(document.querySelector("[data-card-cid='q1']").outerHTML
        .replace('data-card-cid="q1"', 'data-card-cid="blank1"'))
    JS

    assert_selector "[data-survey-editor-target='card']", count: before + 1
  end
end
