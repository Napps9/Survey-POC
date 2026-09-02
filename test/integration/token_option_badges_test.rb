require "test_helper"

# "Show the points on each answer": what an option is worth, on the option,
# before it is picked. Server-rendered in the shared card partial for
# respondents only; the editor keeps its amount inputs and the amounts stay
# hidden until the after-answer reveal unless the creator opts in.
class TokenOptionBadgesTest < ActionDispatch::IntegrationTest
  TYPES = [
    { "id" => "gold", "name" => "Gold Coins", "icon" => "🪙" },
    { "id" => "coal", "name" => "Coal", "icon" => "⚫" }
  ].freeze

  CARDS = [
    { "type" => "multiple_choice", "cid" => "mc", "text" => "Pick one", "options" => %w[Pizza Salad Gamma],
      "tokens" => { "Pizza" => { "gold" => 500000 }, "Salad" => { "coal" => -100 } } },
    { "type" => "yes_no", "cid" => "yn", "text" => "Yes?", "options" => %w[Yes No],
      "tokens" => { "Yes" => { "gold" => 5 } } },
    { "type" => "select_one_grid", "cid" => "grid", "text" => "Grid", "options" => %w[A B],
      "tokens" => { "A" => { "gold" => 2, "coal" => 1 } } },
    { "type" => "scenario", "cid" => "sc", "text" => "Which way?", "options" => %w[Left Right],
      "pages" => [ { "id" => "pg1", "text" => "A fork in the road." } ],
      "tokens" => { "Left" => { "gold" => 1 } } },
    { "type" => "select_many", "cid" => "sm", "text" => "Completion mode", "options" => %w[One Two],
      "token_award_mode" => "completion", "token_award" => { "gold" => 3 },
      "tokens" => { "One" => { "gold" => 9 } } },
    { "type" => "multiple_choice", "cid" => "off", "text" => "Switched off", "options" => %w[X Y],
      "tokens_enabled" => false, "tokens" => { "X" => { "gold" => 7 } } }
  ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "tob-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "tob-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
  end

  def sign_in!
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def tokenised(**attrs)
    @org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                         default_locale: "en", locales: [ "en" ], cards: CARDS.map(&:dup),
                         tokenisation_enabled: true, token_types: TYPES,
                         publish_token: SecureRandom.urlsafe_base64(18),
                         published_at: Time.current, **attrs)
  end

  test "off by default, and the switch round-trips on a live Verto" do
    s = tokenised
    assert_not s.token_amounts_shown?, "new behaviour — opt in"

    sign_in!
    post survey_settings_path(s), params: { token_amounts_shown: "1", return_tab: "tokens" }
    assert s.reload.token_amounts_shown?, "presentation only — never locked once live"
    get survey_path(s)
    assert_select "input[type=checkbox][name='token_amounts_shown'][checked]", count: 1
  end

  test "off: the player shows no amounts anywhere" do
    get play_survey_path(tokenised.publish_token)
    assert_response :success
    assert_select ".token-option-badge", count: 0
  end

  test "on: every awarding option carries its formatted amounts, and nothing else does" do
    s = tokenised(token_amounts_shown: true)
    get play_survey_path(s.publish_token)
    assert_response :success

    assert_select "[data-canonical='Pizza'] .token-option-badge", text: "🪙 500,000"
    assert_select "[data-canonical='Pizza'] .token-option-badge[aria-label='500,000 Gold Coins']"
    assert_select "[data-canonical='Salad'] .token-option-badge", text: "⚫ -100", count: 1
    assert_select "[data-canonical='Gamma'] .token-option-badge", { count: 0 }, "an option worth nothing says nothing"

    assert_select "[data-canonical='Yes'] .token-option-badge", text: "🪙 5"
    assert_select "[data-canonical='No'] .token-option-badge", count: 0

    assert_select ".choice-card[data-canonical='A'] .choice-card-bg .token-option-badge", text: "🪙 2 · ⚫ 1"
    assert_select ".choice-card[data-canonical='B'] .token-option-badge", count: 0

    assert_select "[data-card-type='scenario'] [data-canonical='Left'] .token-option-badge", text: "🪙 1"

    assert_select "[data-canonical='One'] .token-option-badge", { count: 0 },
                  "completion mode earns for answering at all — nothing per option to show"
    assert_select "[data-canonical='X'] .token-option-badge", { count: 0 }, "a card with tokens switched off awards nothing"

    # The badge sits beside the label, never inside it: the player's
    # _canonicalOf falls back to the label's text.
    assert_select ".choice-list-label .token-option-badge", count: 0
    assert_select ".choice-label .token-option-badge", count: 0
  end

  test "no tokenisation, no badges — whatever the switch says" do
    s = tokenised(token_amounts_shown: true, tokenisation_enabled: false)
    get play_survey_path(s.publish_token)
    assert_select ".token-option-badge", count: 0
  end

  test "the editor keeps its amount inputs and shows no badge; owner preview shows what respondents see" do
    s = tokenised(token_amounts_shown: true)
    sign_in!

    get survey_path(s)
    assert_response :success
    assert_select ".token-option-badge", count: 0
    assert_select ".token-amount-input", minimum: 1

    get preview_survey_path(s)
    assert_response :success
    assert_select "[data-canonical='Pizza'] .token-option-badge", text: "🪙 500,000"
  end
end
