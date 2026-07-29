require "test_helper"

# First-class flows, server side: the flows column surviving an editor autosave
# through sanitize_flows, membership reconciliation against the flows list, the
# FlowCompiler backstop rewriting member chains on every save, and the
# published lock covering the new write paths.
class FlowsSanitizeTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "flows-#{SecureRandom.hex(3)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "flows-#{SecureRandom.hex(3)}")
    @org.memberships.create!(user: @user, role: "admin")
    @survey = @org.surveys.create!(
      title: "Regions", theme: "Network", audience_age: "all", key_insight: "x",
      default_locale: "en", locales: [ "en" ], logic: true,
      cards: [
        { "type" => "multiple_choice", "cid" => "c_hub", "text" => "Which region?", "options" => %w[UK UAE USA],
          "logic" => { "routes" => [
            { "match" => { "op" => "equals", "value" => "UK" }, "to" => { "card" => "c_uk1" } }
          ], "default" => { "card" => "c_tail" } } },
        { "type" => "open_ended", "cid" => "c_uk1", "text" => "UK transport", "flow_id" => "f_uk" },
        { "type" => "open_ended", "cid" => "c_uk2", "text" => "UK energy", "flow_id" => "f_uk" },
        { "type" => "open_ended", "cid" => "c_tail", "text" => "Shared tail" }
      ],
      flows: [ { "id" => "f_uk", "name" => "UK", "color" => "#8B85FF", "exit" => { "card" => "c_tail" } } ]
    )
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def patch_survey(payload)
    patch survey_path(@survey), params: payload.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  test "cards + flows round-trip an autosave and the compile backstop writes the member chain" do
    patch_survey(cards: @survey.cards, flows: @survey.flows_list)
    assert_response :success
    @survey.reload
    assert_equal [ { "id" => "f_uk", "name" => "UK", "color" => "#8B85FF", "exit" => { "card" => "c_tail" } } ],
                 @survey.flows_list
    assert_equal %w[f_uk f_uk], @survey.cards.values_at(1, 2).map { |c| c["flow_id"] }
    # The client sent no `next` pointers at all — the server compile is what
    # chains the members and points the last at the exit.
    assert_equal({ "card" => "c_uk2" }, @survey.cards[1]["next"])
    assert_equal({ "card" => "c_tail" }, @survey.cards[2]["next"])
  end

  test "sanitize_flows bounds names, backfills ids, replaces bad colours and drops malformed exits" do
    out = Survey.sanitize_flows([
      { "id" => "f_uk", "name" => "  UK  ", "color" => "#8B85FF", "exit" => { "card" => "c_tail" } },
      { "id" => "not-a-flow-id", "name" => "x" * 100, "color" => "teal", "exit" => "nope" },
      { "id" => "f_uk", "name" => "Duplicate id" }, # collides ⇒ re-minted
      "not-a-hash"
    ])
    assert_equal 3, out.size
    assert_equal %w[f_uk UK], [ out[0]["id"], out[0]["name"] ]
    assert out[1]["id"].match?(Survey::FLOW_ID_FORMAT), "bad id is re-minted"
    assert_equal Survey::MAX_FLOW_NAME, out[1]["name"].length
    assert_includes Survey::FLOW_COLORS, out[1]["color"], "unknown colour shape falls back to the palette"
    refute out[1].key?("exit"), "malformed exit is dropped"
    refute_equal "f_uk", out[2]["id"], "colliding id is re-minted"
    assert out[2]["id"].match?(Survey::FLOW_ID_FORMAT)
  end

  test "sanitize_flows caps the list at MAX_FLOWS" do
    out = Survey.sanitize_flows(Array.new(20) { |i| { "name" => "F#{i}" } })
    assert_equal Survey::MAX_FLOWS, out.size
  end

  test "a card claiming an unknown flow loses its membership" do
    cards = @survey.cards
    cards[3]["flow_id"] = "f_ghost"
    patch_survey(cards: cards, flows: @survey.flows_list)
    assert_response :success
    refute @survey.reload.cards[3].key?("flow_id"), "reconcile_flows! should drop the ghost membership"
  end

  test "a junk flow_id is dropped by the card sanitizer" do
    patch_survey(cards: [ { "type" => "open_ended", "cid" => "c_x", "text" => "Q", "flow_id" => "javascript:alert(1)" } ],
                 flows: [])
    assert_response :success
    refute @survey.reload.cards.first.key?("flow_id")
  end

  test "a flows-only save recompiles the stored deck" do
    # Repoint the UK flow's exit at an end screen without resending cards: the
    # stored last member's `next` must follow.
    patch_survey(flows: [ { "id" => "f_uk", "name" => "UK", "color" => "#8B85FF", "exit" => { "end" => "default" } } ])
    assert_response :success
    assert_equal({ "end" => "default" }, @survey.reload.cards[2]["next"])
  end

  test "deleting a flow via save dissolves membership on the stored deck" do
    patch_survey(flows: [])
    assert_response :success
    @survey.reload
    refute @survey.cards[1].key?("flow_id")
    refute @survey.cards[2].key?("flow_id")
  end

  test "the compiled deck still resolves the regional walk through LogicGraph" do
    patch_survey(cards: @survey.cards, flows: @survey.flows_list)
    cards = @survey.reload.cards
    assert_equal [ 0, 1, 2, 3 ], LogicGraph.resolve_path(cards, { "0" => { "value" => "UK" } })
    assert_equal [ 0, 3 ],       LogicGraph.resolve_path(cards, { "0" => { "value" => "UAE" } })
  end

  test "the editor renders flow identity into the DOM round-trip" do
    get survey_path(@survey)
    assert_response :success
    # The root carries the flows working set the editor's serialize() sends back…
    assert_match "data-survey-editor-flows-value=", response.body
    assert_match "f_uk", response.body
    # …and each member wrap carries its membership for the DOM round-trip.
    assert_select ".survey-card-wrap[data-card-flow-id='f_uk']", 2
  end

  test "the editor renders the Flows panel shell when logic is on" do
    get survey_path(@survey)
    assert_response :success
    assert_select ".flow-panel [data-flows-target='list']"
    assert_select ".flow-panel [data-flows-target='warnings']"
    assert_select ".flow-panel .flow-new-btn"
    # The flows controller rides the editor root, one-root pattern.
    assert_match(/data-controller="[^"]*\bflows\b[^"]*"/, response.body)
  end

  test "a flow-typed exit survives sanitize and compiles into the target flow's entry" do
    cards = @survey.cards
    cards[3]["flow_id"] = "f_shared"
    flows = [ { "id" => "f_uk", "name" => "UK", "color" => "#8B85FF", "exit" => { "flow" => "f_shared" } },
              { "id" => "f_shared", "name" => "Shared", "color" => "#01EACB" } ]
    patch_survey(cards: cards, flows: flows)
    assert_response :success
    @survey.reload
    assert_equal({ "flow" => "f_shared" }, @survey.flows_list.first["exit"], "authoring shape persists")
    assert_equal({ "card" => "c_tail" }, @survey.cards[2]["next"], "compiled to the shared flow's entry")
  end

  test "the feed renders a duplicate button per card on drafts and none when live" do
    get survey_path(@survey)
    assert_select ".card-duplicate-btn", 4
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    get survey_path(@survey)
    assert_select ".card-duplicate-btn", 0
  end

  test "editing flows on a published Verto is locked" do
    @survey.update!(publish_token: SecureRandom.hex(8), published_at: Time.current)
    patch_survey(flows: [])
    assert_response :locked
    assert_equal 1, @survey.reload.flows_list.size
  end
end
