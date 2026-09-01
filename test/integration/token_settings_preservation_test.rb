require "test_helper"

# The editor rebuilds every card from the DOM on autosave and cards replace
# wholesale — but token controls only RENDER while tokenisation is on, so a
# page loaded before the switch was flipped serializes every card with no
# token keys at all. Treating that silence as deletion wiped a deck's amounts
# on the next autosave of anything. serialize() now says whether the client
# could see the controls (tokens_authoritative); these pin the server's
# behaviour in both directions — preserve on silence, but never merge over a
# client that could see the controls, because for that client absence
# legitimately means "zeroed" and a merge would make amounts un-deletable.
class TokenSettingsPreservationTest < ActionDispatch::IntegrationTest
  TYPES = [ { "id" => "t1", "icon" => "⭐", "name" => "Stars" } ].freeze
  CARDS = [
    { "type" => "welcome_card", "title" => "hi", "cid" => "c_welcome" },
    { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ], "cid" => "c_q1",
      "tokens" => { "Yes" => { "t1" => 5 } } },
    { "type" => "multiple_choice", "text" => "Pick", "options" => [ "A", "B" ], "cid" => "c_q2",
      "token_award" => { "t1" => 2 }, "token_award_mode" => "completion" },
    { "type" => "open_ended", "text" => "Why?", "cid" => "c_q3",
      "token_award" => { "t1" => 3 }, "tokens_enabled" => false }
  ].freeze
  TOKEN_KEYS = Survey::TOKEN_SETTING_KEYS

  def setup
    @user = User.create!(name: "U", email_address: "tsp-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "tsp-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    # Unpublished, no responses — a PATCHable deck (editing_locked? is false).
    @survey = @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                   default_locale: "en", locales: [ "en" ],
                                   cards: JSON.parse(CARDS.to_json),
                                   tokenisation_enabled: true, token_types: JSON.parse(TYPES.to_json))
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def patch_cards(cards, **extra)
    patch survey_path(@survey),
          params: { title: "T", cards: cards, **extra }.to_json,
          headers: { "Content-Type" => "application/json" }
    assert_response :success
    @survey.reload
  end

  def stripped_cards
    JSON.parse(CARDS.to_json).map { |c| c.except(*TOKEN_KEYS) }
  end

  def card(cid)
    @survey.cards.find { |c| c["cid"] == cid }
  end

  test "a client that could not see the token controls cannot delete them" do
    patch_cards(stripped_cards, tokens_authoritative: false)

    assert_equal({ "Yes" => { "t1" => 5 } }, card("c_q1")["tokens"])
    assert_equal({ "t1" => 2 }, card("c_q2")["token_award"])
    assert_equal "completion", card("c_q2")["token_award_mode"]
    assert_equal({ "t1" => 3 }, card("c_q3")["token_award"])
    assert_equal false, card("c_q3")["tokens_enabled"],
                 "the explicit OFF is one of the carried keys — losing it silently re-arms the award"
  end

  test "an older client that sends no flag at all preserves too" do
    patch_cards(stripped_cards)

    assert_equal({ "Yes" => { "t1" => 5 } }, card("c_q1")["tokens"])
    assert_equal false, card("c_q3")["tokens_enabled"]
  end

  test "a client that saw the controls zeroes by omission" do
    patch_cards(stripped_cards, tokens_authoritative: true)

    TOKEN_KEYS.each do |key|
      %w[c_q1 c_q2 c_q3].each do |cid|
        assert_nil card(cid)[key],
                   "#{cid}'s #{key} was merged back over an authoritative save — " \
                   "all-zero amounts serialize as no key, so this makes them un-deletable"
      end
    end
  end

  test "a client that saw the controls writes what it sends" do
    cards = stripped_cards
    cards[1]["tokens"] = { "Yes" => { "t1" => 9 } }
    patch_cards(cards, tokens_authoritative: true)

    assert_equal({ "Yes" => { "t1" => 9 } }, card("c_q1")["tokens"])
  end

  test "a card the store has never seen passes through untouched" do
    cards = stripped_cards
    cards << { "type" => "open_ended", "text" => "New", "cid" => "c_new",
               "token_award" => { "t1" => 8 } }
    patch_cards(cards, tokens_authoritative: false)

    assert_equal({ "t1" => 8 }, card("c_new")["token_award"],
                 "a new card has no stored counterpart — its own keys must survive the carry")
    assert_equal({ "Yes" => { "t1" => 5 } }, card("c_q1")["tokens"])
  end

  test "a PATCH without cards leaves the deck's token config alone" do
    patch survey_path(@survey),
          params: { title: "Renamed" }.to_json,
          headers: { "Content-Type" => "application/json" }
    assert_response :success
    @survey.reload

    assert_equal "Renamed", @survey.title
    assert_equal({ "Yes" => { "t1" => 5 } }, card("c_q1")["tokens"])
    assert_equal false, card("c_q3")["tokens_enabled"]
  end
end
