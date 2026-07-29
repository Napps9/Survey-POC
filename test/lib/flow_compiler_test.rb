require "test_helper"

# FlowCompiler turns first-class flows (surveys.flows + per-card flow_id) into
# the per-card `next` chains LogicGraph / the live player already resolve —
# these tests lock that compilation contract. The client mirror is
# survey_editor_controller.js#_compileFlows.
class FlowCompilerTest < ActiveSupport::TestCase
  # The canonical regional example: a hub question routes "UK" into a
  # two-card UK flow that converges back onto a shared tail card.
  def region_deck
    [
      { "cid" => "c_hub", "type" => "multiple_choice", "text" => "Which region?",
        "options" => %w[UK UAE USA],
        "logic" => { "routes" => [
          { "match" => { "op" => "equals", "value" => "UK" }, "to" => { "card" => "c_uk1" } }
        ], "default" => { "card" => "c_tail" } } },
      { "cid" => "c_uk1", "type" => "open_ended", "text" => "UK transport", "flow_id" => "f_uk" },
      { "cid" => "c_uk2", "type" => "open_ended", "text" => "UK energy", "flow_id" => "f_uk" },
      { "cid" => "c_tail", "type" => "open_ended", "text" => "Shared tail" }
    ]
  end

  def uk_flow(exit_target = { "card" => "c_tail" })
    { "id" => "f_uk", "name" => "UK", "color" => "#8B85FF", "exit" => exit_target }
  end

  test "chains members in deck order and points the last at the exit card" do
    cards = FlowCompiler.compile!(region_deck, [ uk_flow ])
    assert_equal({ "card" => "c_uk2" }, cards[1]["next"])
    assert_equal({ "card" => "c_tail" }, cards[2]["next"])
  end

  test "an end exit compiles to an end target" do
    cards = FlowCompiler.compile!(region_deck, [ uk_flow({ "end" => "uk_hub" }) ])
    assert_equal({ "end" => "uk_hub" }, cards[2]["next"])
  end

  test "an absent exit clears the last member's next so it falls through linearly" do
    deck = region_deck
    deck[2]["next"] = { "card" => "c_hub" } # stale pointer from an earlier wiring
    cards = FlowCompiler.compile!(deck, [ uk_flow(nil) ])
    assert_equal({ "card" => "c_uk2" }, cards[1]["next"])
    refute cards[2].key?("next"), "no exit ⇒ the last member falls through to the linear next"
  end

  test "a malformed exit carrying both keys resolves like LogicGraph (end wins)" do
    cards = FlowCompiler.compile!(region_deck, [ uk_flow({ "card" => "c_tail", "end" => "uk_hub" }) ])
    assert_equal({ "end" => "uk_hub" }, cards[2]["next"])
  end

  test "cards outside any flow are untouched" do
    before = region_deck
    after  = FlowCompiler.compile!(JSON.parse(before.to_json), [ uk_flow ])
    assert_equal before[0], after[0], "the hub question must round-trip byte-identical"
    assert_equal before[3], after[3], "the shared tail must round-trip byte-identical"
  end

  test "compilation is idempotent" do
    once  = FlowCompiler.compile!(region_deck, [ uk_flow ])
    twice = FlowCompiler.compile!(JSON.parse(once.to_json), [ uk_flow ])
    assert_equal once, twice
  end

  test "an empty or unknown flow is a no-op" do
    empty = { "id" => "f_none", "name" => "Empty", "color" => "#01EACB" }
    assert_equal region_deck, FlowCompiler.compile!(region_deck, [ empty ])
    assert_equal region_deck, FlowCompiler.compile!(region_deck, [ "not-a-hash", nil ])
  end

  test "a compiled regional deck resolves end-to-end through LogicGraph" do
    cards = FlowCompiler.compile!(region_deck, [ uk_flow ])
    answers = { "0" => { "type" => "multiple_choice", "value" => "UK" } }
    assert_equal [ 0, 1, 2, 3 ], LogicGraph.resolve_path(cards, answers),
                 "UK answer should walk the whole UK flow then converge on the tail"
    assert_equal [ 0, 3 ], LogicGraph.resolve_path(cards, { "0" => { "value" => "UAE" } }),
                 "a non-routed answer takes the hub's default straight to the tail"
  end

  test "members lists a flow's cards in deck order" do
    assert_equal %w[c_uk1 c_uk2], FlowCompiler.members(region_deck, "f_uk").map { |c| c["cid"] }
    assert_empty FlowCompiler.members(region_deck, "")
    assert_empty FlowCompiler.members(region_deck, nil)
  end
end
