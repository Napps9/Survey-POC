require "test_helper"

# Phase 1 of answer-branching ("logic"): the survey-level toggle, card identity
# (cid) surviving autosave, routes surviving a reorder, dangling routes failing
# safe, the published-lock, and the player deck carrying the routing config.
class LogicBranchingTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "logic-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "logic-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Hub", theme: "Sports", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], logic: true,
      cards: [
        { "type" => "multiple_choice", "cid" => "c_hub", "text" => "Which hub?", "options" => %w[UK US],
          "logic" => { "routes" => [
            { "match" => { "op" => "equals", "value" => "UK" }, "to" => { "card" => "c_uk" } }
          ], "default" => { "card" => "c_us" } } },
        { "type" => "open_ended", "cid" => "c_uk", "text" => "UK page" },
        { "type" => "open_ended", "cid" => "c_us", "text" => "US page" }
      ]
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def patch_cards(cards)
    patch survey_path(@survey), params: { cards: cards }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  test "update_settings toggles the survey logic flag" do
    plain = @org.surveys.create!(title: "P", theme: "t", audience_age: "all", key_insight: "k",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    post survey_settings_path(plain), params: { logic: "1" }
    assert plain.reload.logic?
    post survey_settings_path(plain), params: { logic: "0" }
    refute plain.reload.logic?
  end

  test "autosave preserves cid + logic through sanitize" do
    patch_cards(@survey.cards) # round-trip the current deck
    assert_response :success
    @survey.reload
    assert_equal %w[c_hub c_uk c_us], @survey.cards.map { |c| c["cid"] }
    assert_equal "c_uk", @survey.cards.first.dig("logic", "routes", 0, "to", "card")
  end

  test "a card arriving without a cid is stamped one server-side" do
    patch_cards([ { "type" => "yes_no", "text" => "New?" } ])
    assert_response :success
    @survey.reload
    assert @survey.cards.first["cid"].to_s.start_with?("c_"), "server backstop should stamp a cid"
  end

  test "malformed logic is dropped by sanitize" do
    patch_cards([ { "type" => "multiple_choice", "cid" => "c_x", "text" => "Q", "logic" => "not-a-hash" } ])
    assert_response :success
    refute @survey.reload.cards.first.key?("logic")
  end

  test "the per-card next pointer survives sanitize; a malformed one is dropped" do
    patch_cards([
      { "type" => "open_ended", "cid" => "c_a", "text" => "A", "next" => { "card" => "c_b" } },
      { "type" => "open_ended", "cid" => "c_b", "text" => "B", "next" => "nonsense" }
    ])
    assert_response :success
    cards = @survey.reload.cards
    assert_equal({ "card" => "c_b" }, cards[0]["next"])
    refute cards[1].key?("next"), "a non-hash next is dropped"
  end

  test "a branch lane_label is kept (bounded) and blank ones are dropped" do
    patch_cards([
      { "type" => "open_ended", "cid" => "c_a", "text" => "A", "lane_label" => "  UK hub  " },
      { "type" => "open_ended", "cid" => "c_b", "text" => "B", "lane_label" => "   " },
      { "type" => "open_ended", "cid" => "c_c", "text" => "C", "lane_label" => "x" * 200 }
    ])
    assert_response :success
    cards = @survey.reload.cards
    assert_equal "UK hub", cards[0]["lane_label"]           # trimmed
    refute cards[1].key?("lane_label")                       # blank ⇒ dropped
    assert_equal Survey::MAX_LANE_LABEL, cards[2]["lane_label"].length # bounded
  end

  test "routes still resolve after a reorder (cids are stable, no remap)" do
    reordered = [ @survey.cards[2], @survey.cards[0], @survey.cards[1] ] # US, hub, UK
    patch_cards(reordered)
    assert_response :success
    @survey.reload
    cards   = @survey.cards
    hub_idx = cards.index { |c| c["cid"] == "c_hub" }
    answers = { hub_idx.to_s => { "value" => "UK" } }
    # UK still routes to c_uk wherever it now sits in the array.
    assert_equal cards.index { |c| c["cid"] == "c_uk" },
                 LogicGraph.next_index(cards, hub_idx, answers)
  end

  test "a dangling route target fails safe to the linear next card" do
    # Drop c_uk; the hub's UK route now points at a missing card.
    patch_cards([ @survey.cards[0], @survey.cards[2] ]) # hub, US only
    assert_response :success
    cards = @survey.reload.cards
    # UK route is dangling ⇒ next_index falls through to the linear next (idx 1).
    assert_equal 1, LogicGraph.next_index(cards, 0, { "0" => { "value" => "UK" } })
  end

  test "editing logic on a published Verto is locked" do
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    patch_cards(@survey.cards)
    assert_response :locked
  end

  test "the editor renders per-option route selects and the default row when logic is on" do
    get survey_path(@survey)
    assert_response :success
    # One route select per option (2 hub options) + a default row select, on the
    # single-pick hub card; the open_ended cards get none.
    assert_select "select.logic-route-select[data-logic-route][data-canonical='UK']"
    assert_select "select.logic-route-select[data-logic-route][data-canonical='US']"
    assert_select "select.logic-route-select[data-logic-default]", minimum: 1
    assert_match 'data-survey-editor-logic-value="true"', response.body
    # The activation toggle lives in the right panel's Logic & flows tab now.
    assert_match "Logic &amp; flows", response.body
    assert_select ".right-tabs .right-tab--logic"
  end

  test "no route selects render when logic is off" do
    @survey.update!(logic: false)
    get survey_path(@survey)
    assert_response :success
    assert_select "select.logic-route-select", false
  end

  test "the player deck carries cid and routing config when logic is on" do
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    get play_survey_path(@survey.publish_token)
    assert_response :success
    assert_match 'data-player-logic-value="true"', response.body
    assert_match 'data-card-cid="c_hub"', response.body
    assert_match "data-card-logic=", response.body
  end

  # ── Phase 3: extra end screens ──────────────────────────────────────────────

  test "sanitize_end_screens drops the reserved default id, caps, requires content" do
    out = Survey.sanitize_end_screens([
      { "id" => "default", "title" => "should be dropped" },
      { "id" => "uk_hub", "title" => "Join UK", "forward_url" => "https://buy.stripe.com/uk", "forward_label" => "Pay" },
      { "title" => "", "body" => "", "forward_url" => "" } # no content ⇒ dropped
    ])
    assert_equal 1, out.size
    assert_equal "uk_hub", out.first["id"]
    assert_equal "https://buy.stripe.com/uk", out.first["forward_url"]
  end

  test "end_screens_list is the default screen plus extras" do
    @survey.update!(thankyou_title: "Cheers", end_screens: [ { "id" => "uk_hub", "title" => "Join UK" } ])
    ids = @survey.end_screens_list.map { |s| s["id"] }
    assert_equal %w[default uk_hub], ids
    assert_equal "Cheers", @survey.end_screen("default")["title"]
    assert_equal "Join UK", @survey.end_screen("uk_hub")["title"]
    assert_equal "Cheers", @survey.end_screen("missing")["title"] # unknown ⇒ default
  end

  test "update_settings persists sanitized end screens" do
    post survey_settings_path(@survey), params: {
      end_screens: [ { "id" => "uk_hub", "title" => "Join the UK hub", "forward_url" => "https://buy.stripe.com/uk" } ].to_json
    }
    screens = @survey.reload.read_attribute(:end_screens)
    assert_equal 1, screens.size
    assert_equal "uk_hub", screens.first["id"]
  end

  test "the player carries end-screen data and an (initially hidden) forward CTA" do
    @survey.update!(end_screens: [ { "id" => "uk_hub", "title" => "Join the UK hub", "forward_url" => "https://buy.stripe.com/uk" } ],
                    publish_token: SecureRandom.hex(8), published_at: Time.current)
    get play_survey_path(@survey.publish_token)
    assert_response :success
    assert_match "data-player-end-screens-value=", response.body
    assert_match "uk_hub", response.body
    assert_select "a.hidden[data-player-target='forwardBtn']" # no default forward_url ⇒ hidden
  end

  test "the editor mounts the Journey (button + overlay) only when logic is on" do
    get survey_path(@survey)
    assert_response :success
    assert_match(/data-controller="[^"]*\bjourney\b[^"]*"/, response.body) # controller on the root
    assert_match "click->journey#open", response.body             # the Journey buttons + tab
    assert_select "[data-journey-target='wires']"                 # the overlay's wire canvas
    assert_select "[data-journey-target='canvas']"
    assert_match "data-journey-ends-value", response.body
    assert_match 'data-journey-editable-value="true"', response.body # draft ⇒ editable canvas

    @survey.update!(logic: false)
    get survey_path(@survey)
    assert_response :success
    assert_select "[data-journey-target='wires']", false
  end

  test "the editor lists extra end screens as route targets and offers the manager" do
    @survey.update!(end_screens: [ { "id" => "uk_hub", "title" => "Join the UK hub" } ])
    get survey_path(@survey)
    assert_response :success
    assert_match "uk_hub", response.body                 # in the logic-config ends
    assert_match "Branch end screens", response.body      # the manager block
    assert_select "[data-controller='end-screens']"
  end
end
