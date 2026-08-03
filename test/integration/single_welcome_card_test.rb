require "test_helper"

# The other half of "delete a welcome card" (1b.3). Un-suppressing delete and
# reorder shipped earlier; what was still missing was the rule that stops the
# opposite problem — a deck with TWO welcome cards, which greets the respondent
# twice. Nothing enforced it: welcome_card was pickable like any other type, and
# any card could be converted into one.
class SingleWelcomeCardTest < ActionDispatch::IntegrationTest
  def org
    @org ||= Organisation.create!(name: "O", slug: "sw-#{SecureRandom.hex(3)}")
  end

  def survey(cards)
    org.surveys.create!(title: "W", theme: "T", audience_age: "all", key_insight: "k",
                        default_locale: "en", locales: [ "en" ], cards: cards)
  end

  def sign_in!
    user = User.create!(name: "U", email_address: "sw-#{SecureRandom.hex(3)}@test.com",
                        password: "verylongpassword")
    org.memberships.create!(user: user, role: "admin")
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  WELCOME  = { "type" => "welcome_card", "title" => "First hello" }.freeze
  WELCOME2 = { "type" => "welcome_card", "title" => "Second hello" }.freeze
  QUESTION = { "type" => "yes_no", "cid" => "q1", "text" => "Ok?", "options" => %w[Yes No] }.freeze

  # ── The sanitizer rule ────────────────────────────────────────────────────

  test "a second welcome card is dropped, keeping the first" do
    deck = Survey.sanitize_cards_images!([ WELCOME.dup, QUESTION.dup, WELCOME2.dup ], warnings: [])
    assert_equal %w[welcome_card yes_no], deck.map { |c| c["type"] }
    assert_equal "First hello", deck.first["title"]
  end

  # Dropped, not rejected — decks with two welcome cards already exist, and a
  # validation error would 422 their every autosave from now on. But not
  # silently either: the drop reports through the same warnings channel a
  # rejected image uses, which the editor shows as a save warning.
  test "the drop is reported through the warnings channel" do
    warnings = []
    Survey.sanitize_cards_images!([ WELCOME.dup, WELCOME2.dup ], warnings: warnings)
    assert_includes warnings, "duplicate_welcome"
  end

  test "a single welcome card is untouched and unwarned" do
    warnings = []
    deck = Survey.sanitize_cards_images!([ WELCOME.dup, QUESTION.dup ], warnings: warnings)
    assert_equal %w[welcome_card yes_no], deck.map { |c| c["type"] }
    refute_includes warnings, "duplicate_welcome"
  end

  # The full round trip: the editor PATCHes a deck carrying a duplicate, one
  # survives, and the response tells the editor something didn't stick.
  test "an autosave carrying a duplicate welcome saves one and warns" do
    sign_in!
    s = survey([ WELCOME.dup, QUESTION.dup ])

    patch survey_path(s), params: { cards: [ WELCOME, QUESTION, WELCOME2 ] }.to_json,
                          headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    assert_equal %w[welcome_card yes_no], s.reload.cards.map { |c| c["type"] }
    assert_includes Array(JSON.parse(response.body)["warnings"]), "duplicate_welcome",
                    "the editor must be told the duplicate was dropped, not left to notice on reload"
  end

  # ── The picker ────────────────────────────────────────────────────────────

  test "the picker stops offering Welcome once the deck has one" do
    refute_includes CardTypes.pickable_for(survey([ WELCOME.dup, QUESTION.dup ])).map(&:first),
                    "welcome_card"
  end

  test "the picker offers Welcome to a deck without one" do
    assert_includes CardTypes.pickable_for(survey([ QUESTION.dup ])).map(&:first), "welcome_card"
  end

  test "the add-question modal renders no Welcome tile when one exists" do
    sign_in!
    s = survey([ WELCOME.dup, QUESTION.dup ])
    get survey_path(s)
    assert_response :success
    assert_select ".aq-type-tile[data-type='welcome_card']", count: 0
  end

  test "the add-question modal offers Welcome when the deck has none" do
    sign_in!
    s = survey([ QUESTION.dup ])
    get survey_path(s)
    assert_response :success
    assert_select ".aq-type-tile[data-type='welcome_card']", count: 1
  end
end
