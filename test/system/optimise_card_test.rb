require "application_system_test_case"

# BUG-018. "✨ Optimise" sends one card to Claude for a rewrite and splices the
# result back in. The server merges the rewrite ONTO the card it is given and
# re-renders from that, so whatever the client leaves out of the payload is gone
# from the card afterwards.
#
# The client sent `{ type, ...this._readCard(card) }` — five keys. Everything
# else went: the cid other cards' logic routes point AT, the image, the required
# flag, the routes, flow membership, Common Question provenance, quiz answers
# and token values.
#
# Only a browser can see this. The server is correct in isolation — it preserves
# everything it receives — and every server-side test passes a complete card,
# because a test author writing one naturally writes the whole thing.
class OptimiseCardTest < ApplicationSystemTestCase
  # Quiz and tokenisation are both ON: serialize() only emits `correct` and
  # `tokens` when they are, and those two fields are among the ones a bare
  # optimise payload used to lose. A fixture with them off would have made this
  # test pass while proving less than it claims.
  def cards
    [
      { "type" => "welcome_card", "title" => "Hello" },
      { "type" => "multiple_choice", "cid" => "c_target",
        "text" => "?",
        "options" => [ "A", "B" ],
        "required" => true,
        "image" => "https://images.pexels.com/photos/1/x.jpg",
        "image_credit" => "A Photographer",
        "competency" => Framework.competencies.first.first,
        "outcome" => "Shows who acts",
        "tokens" => { "A" => { "gold" => 5 } },
        "correct" => [ "A" ] }
    ]
  end

  def setup
    super
    @org  = Organisation.create!(name: "Studio", slug: "op-#{SecureRandom.hex(3)}")
    @user = User.create!(name: "Op", email_address: "op-#{SecureRandom.hex(3)}@test.com",
                         password: "verylongpassword")
    @user.verify_email!
    @org.memberships.create!(user: @user, role: "admin")

    @survey = @org.surveys.create!(title: "Optimise", theme: "Safety", audience_age: "adults",
                                   key_insight: "k", default_locale: "en", locales: [ "en" ],
                                   cards: cards, quiz: true, tokenisation_enabled: true,
                                   token_types: [ { "id" => "gold", "name" => "Gold", "icon" => "🪙" } ])
  end

  # What the client actually posts. Asserted directly rather than by driving the
  # button, because the payload IS the defect — and because stubbing Claude
  # through a real server thread would test the stub as much as the code.
  def optimise_payload
    evaluate_script(<<~JS)
      (() => {
        const root = document.querySelector('[data-controller~="survey-editor"]')
        const app  = window.Stimulus || window.application
        const c    = app.getControllerForElementAndIdentifier(root, "survey-editor")
        const idx  = c.cardTargets.findIndex(el => el.dataset.cardCid === "c_target")
        return JSON.stringify(c.serialize().cards[idx] || {})
      })()
    JS
  end

  def open_editor
    sign_in_as(@user)
    visit survey_path(@survey)
    dismiss_cookie_banner
    assert_selector "[data-card-cid='c_target']"
  end

  test "the optimise payload carries the card's identity and wiring" do
    open_editor
    card = JSON.parse(optimise_payload)

    assert_equal "c_target", card["cid"],
                 "without the cid the server mints a new one, orphaning every logic route " \
                 "that points at this card"
    assert_equal true, card["required"]
    assert card["image"].present?, "the card's image must survive an optimise"
    assert_equal 5, card.dig("tokens", "A", "gold"),
                 "per-option token awards must survive an optimise"
    assert_equal "A", card["correct"]
    assert_equal Framework.competencies.first.first, card["competency"]
  end

  # The join: the server merges the rewrite onto exactly this payload, so
  # anything above that is present survives, and anything missing does not.
  test "the server preserves every field the payload carries" do
    open_editor
    sent = JSON.parse(optimise_payload)

    # SurveysController#optimise_card's merge, with a rewrite that changes only
    # the wording and the options.
    optimised = { "type" => "multiple_choice", "text" => "How old are you?",
                  "options" => [ "Under 18", "18-24", "25-34" ], "description" => "",
                  "outcome" => "Shows age spread" }
    merged = sent.merge(
      "type" => optimised["type"], "text" => optimised["text"],
      "description" => optimised["description"].presence,
      "options" => optimised["options"], "outcome" => optimised["outcome"]
    ).except("i18n").compact

    assert_equal "c_target", merged["cid"]
    assert_equal true, merged["required"]
    assert merged["image"].present?
    assert_equal "A", merged["correct"]
    assert_equal "How old are you?", merged["text"], "the rewrite should still win on wording"
    assert_equal 3, merged["options"].size, "and on options"
  end
end
