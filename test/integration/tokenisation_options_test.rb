require "test_helper"

# Phase 1d: the tokenisation and end-screen behaviours that used to be
# hardcoded. Two different defaults on purpose — see the migration.
class TokenisationOptionsTest < ActionDispatch::IntegrationTest
  CARDS = [
    { "type" => "welcome_card", "title" => "hi", "cid" => "c_welcome" },
    { "type" => "yes_no", "text" => "Like sport?", "options" => [ "Yes", "No" ], "cid" => "c_q1",
      "tokens" => { "Yes" => { "t1" => 5 } } },
    { "type" => "open_ended", "text" => "Why?", "cid" => "c_q2", "token_award" => { "t1" => 3 } }
  ].freeze
  TYPES = [ { "id" => "t1", "icon" => "⭐", "name" => "Stars" } ].freeze

  def setup
    @user = User.create!(name: "U", email_address: "tok-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "tok-#{SecureRandom.hex(3)}")
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

  # ── Defaults: nothing changes for an existing Verto ───────────────────────

  test "the new behaviours default off, and the existing ones default on" do
    s = tokenised
    assert_not s.token_reveal_enabled?,   "new behaviour — opt in"
    assert_not s.token_back_nav_enabled?, "new behaviour — opt in"
    assert s.share_enabled?,   "Share has always been on; defaulting off would withdraw it"
    assert s.regions_enabled?, "same for the regions map"
    assert_nil s.token_intro_cid, "nil means the welcome card, where it was hardcoded"
  end

  # ── Item 1: the token intro moves off the welcome card ────────────────────

  test "the intro defaults to the welcome card and follows an explicit cid" do
    s = tokenised
    assert_equal 0, s.token_intro_index
    assert_equal "c_welcome", s.token_intro_selected_cid

    s.update!(token_intro_cid: "c_q2")
    assert_equal 2, s.token_intro_index
    assert_equal "c_q2", s.token_intro_selected_cid
  end

  test "a stale cid falls back to the welcome card rather than vanishing" do
    s = tokenised(token_intro_cid: "c_deleted")
    assert_equal 0, s.token_intro_index
  end

  test "with no welcome card the intro falls back to the first card" do
    s = tokenised
    s.update!(cards: CARDS.drop(1).map(&:dup))
    assert_equal 0, s.reload.token_intro_index
    assert_equal "c_q1", s.token_intro_selected_cid
  end

  # The reason this resolves to an index rather than a cid: a deck built outside
  # the editor's save path (the demo seeder, a raw import) has no cids at all,
  # and cid matching would drop the intro entirely — a regression against the old
  # hardcoded behaviour.
  test "a deck with no cids still shows the intro on its welcome card" do
    s = tokenised
    s.update!(cards: CARDS.map { |c| c.except("cid") })

    assert_equal 0, s.reload.token_intro_index
    assert_nil s.token_intro_selected_cid, "nothing for the picker to mark, but the intro still places"

    get play_survey_path(s.publish_token)
    assert_response :success
    assert_select ".welcome-intake-tokens", count: 1
  end

  test "the intro has no position when the Verto isn't tokenised" do
    s = tokenised(tokenisation_enabled: false)
    assert_nil s.token_intro_index
  end

  test "an empty deck has no intro position" do
    s = tokenised
    s.update!(cards: [])
    assert_nil s.reload.token_intro_index
  end

  test "the player renders the intro on the chosen card, once" do
    s = tokenised(token_intro_cid: "c_q2")
    get play_survey_path(s.publish_token)
    assert_response :success

    assert_select ".welcome-intake-tokens", count: 1
    assert_select "[data-card-cid='c_q2'] .welcome-intake-tokens"
    assert_select "[data-card-cid='c_welcome'] .welcome-intake-tokens", false
  end

  test "update_settings moves the intro, and ignores a cid not in the deck" do
    sign_in!
    s = tokenised
    post survey_settings_path(s), params: { token_intro_cid: "c_q1" }
    assert_equal "c_q1", s.reload.token_intro_cid

    post survey_settings_path(s), params: { token_intro_cid: "c_nonsense" }
    assert_nil s.reload.token_intro_cid, "stored as nil, so it degrades to the welcome card"
  end

  # ── Item 3: explicit per-question on/off ──────────────────────────────────

  test "an explicit tokens_enabled false stops a card awarding" do
    card = { "type" => "yes_no", "text" => "Q", "tokens" => { "Yes" => { "t1" => 5 } } }
    assert TokenGrading.awarding?(card)
    assert_not TokenGrading.awarding?(card.merge("tokens_enabled" => false))
    assert TokenGrading.awarding?(card.merge("tokens_enabled" => true)),
           "true and absent both mean enabled"
  end

  test "a disabled card earns nothing, even with amounts still configured" do
    cards = [ { "type" => "yes_no", "text" => "Q", "tokens" => { "Yes" => { "t1" => 5 } },
                "tokens_enabled" => false } ]
    totals = TokenGrading.totals(cards, { "0" => { "value" => "Yes" } }, [ "t1" ])
    assert_equal({ "t1" => 0 }, totals)
  end

  test "the flag survives the sanitiser only when it is an explicit off" do
    off = Survey.sanitize_cards_images!([ { "type" => "yes_no", "text" => "Q", "tokens_enabled" => false } ])
    assert_equal false, off.first["tokens_enabled"]

    # A JSON "false" string would read as truthy against `== false`, so it's cast.
    cast = Survey.sanitize_cards_images!([ { "type" => "yes_no", "text" => "Q", "tokens_enabled" => "false" } ])
    assert_equal false, cast.first["tokens_enabled"]

    on = Survey.sanitize_cards_images!([ { "type" => "yes_no", "text" => "Q", "tokens_enabled" => true } ])
    assert_not on.first.key?("tokens_enabled"), "enabled is the absence of the key"
  end

  test "a disabled card is left out of the awarding count" do
    s = tokenised
    assert_equal 2, s.token_awarding_count
    s.update!(cards: s.cards.map { |c| c["cid"] == "c_q1" ? c.merge("tokens_enabled" => false) : c })
    assert_equal 1, s.reload.token_awarding_count
  end

  test "the editor renders the per-question switch, checked unless explicitly off" do
    sign_in!
    s = tokenised(publish_token: nil, published_at: nil)
    get survey_path(s)
    assert_select "[data-token-enabled][checked]", minimum: 1

    s.update!(cards: s.cards.map { |c| c["cid"] == "c_q1" ? c.merge("tokens_enabled" => false) : c })
    get survey_path(s)
    assert_select "[data-token-enabled]:not([checked])", minimum: 1
  end

  # ── Item 4: the back-navigation rule ──────────────────────────────────────
  # The server has always accepted a late answer to a skipped card; the fix was
  # on the client. What's testable server-side is that the promise holds.

  test "the server accepts a late answer to a skipped tokenised card" do
    s = tokenised
    token = SecureRandom.uuid

    post progress_survey_path(s.publish_token),
         params: { session_token: token, answers: { "2" => { "value" => "because" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    # Card 1 was skipped — answering it later must still count.
    post progress_survey_path(s.publish_token),
         params: { session_token: token, answers: { "1" => { "value" => "Yes" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :success

    resp = s.responses.find_by(session_token: token)
    assert_equal "Yes", resp.answers["1"]["value"]
    assert_equal 8, resp.token_totals["t1"], "5 for the late answer plus 3 for the open text"
  end

  test "an already-answered tokenised card still cannot be changed" do
    s = tokenised
    token = SecureRandom.uuid

    post progress_survey_path(s.publish_token),
         params: { session_token: token, answers: { "1" => { "value" => "Yes" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    post progress_survey_path(s.publish_token),
         params: { session_token: token, answers: { "1" => { "value" => "No" } } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }

    assert_equal "Yes", s.responses.find_by(session_token: token).answers["1"]["value"]
  end

  test "the player is told about both token behaviours" do
    s = tokenised(token_reveal_enabled: true, token_back_nav_enabled: true)
    get play_survey_path(s.publish_token)
    assert_select "[data-player-token-reveal-value='true']"
    assert_select "[data-player-token-back-nav-value='true']"
  end

  # ── Items 5 and 6: Share and the regions map ──────────────────────────────

  test "Share renders by default and disappears when switched off" do
    s = tokenised
    get play_survey_path(s.publish_token)
    assert_select "[data-player-target='shareBtn']"

    s.update!(share_enabled: false)
    get play_survey_path(s.publish_token)
    assert_select "[data-player-target='shareBtn']", false
  end

  test "the regions CTA disappears when switched off" do
    s = tokenised
    get play_survey_path(s.publish_token)
    assert_select "[data-player-target='regionsBtn']"

    s.update!(regions_enabled: false)
    get play_survey_path(s.publish_token)
    assert_select "[data-player-target='regionsBtn']", false
  end

  # Hiding the CTA isn't enough — the endpoint is public.
  test "the regions endpoint 403s when switched off" do
    s = tokenised
    get player_regions_path(s.publish_token)
    assert_response :success

    s.update!(regions_enabled: false)
    get player_regions_path(s.publish_token)
    assert_response :forbidden
    assert_not JSON.parse(response.body)["ok"]
  end

  test "both switches are editable on a live Verto" do
    sign_in!
    s = tokenised
    post survey_settings_path(s), params: { share_enabled: "0", regions_enabled: "0" }
    s.reload
    assert_not s.share_enabled?
    assert_not s.regions_enabled?
  end

  test "the token behaviour switches are editable on a live Verto too" do
    sign_in!
    s = tokenised
    post survey_settings_path(s), params: { token_reveal_enabled: "1", token_back_nav_enabled: "1" }
    s.reload
    assert s.token_reveal_enabled?
    assert s.token_back_nav_enabled?
  end

  # ── Item 7: the HUD toggle — a "blind scoring" opt-out ────────────────────

  test "the HUD defaults on, like Share and the regions map" do
    s = tokenised
    assert s.token_hud_enabled?
  end

  test "the HUD toggle is editable on a live Verto" do
    sign_in!
    s = tokenised
    post survey_settings_path(s), params: { token_hud_enabled: "0" }
    assert_not s.reload.token_hud_enabled?

    post survey_settings_path(s), params: { token_hud_enabled: "1" }
    assert s.reload.token_hud_enabled?
  end
end
