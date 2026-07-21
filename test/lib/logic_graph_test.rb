require "test_helper"

# Answer-branching is resolved by pure functions over (cards, answers); this
# locks the routing rules the live player (player_controller.js _resolveNext)
# mirrors client-side. Targets reference cards by stable cid, never index.
class LogicGraphTest < ActiveSupport::TestCase
  # The UK/UAE/US hub deck: Q0 routes UK→c_uk, US→c_us, UAE→end "uae_hub",
  # default→c_generic. c_uk / c_us / c_generic then flow linearly to the end.
  def hub_cards
    [
      { "cid" => "c_hub", "type" => "multiple_choice", "text" => "Which hub?",
        "options" => %w[UK UAE US],
        "logic" => {
          "routes" => [
            { "match" => { "op" => "equals", "value" => "UK" },  "to" => { "card" => "c_uk" } },
            { "match" => { "op" => "equals", "value" => "UAE" }, "to" => { "end" => "uae_hub" } },
            { "match" => { "op" => "equals", "value" => "US" },  "to" => { "card" => "c_us" } }
          ],
          "default" => { "card" => "c_generic" }
        } },
      { "cid" => "c_uk",      "type" => "open_ended", "text" => "UK Stripe" },
      { "cid" => "c_us",      "type" => "open_ended", "text" => "US Stripe" },
      { "cid" => "c_generic", "type" => "open_ended", "text" => "Generic" }
    ]
  end

  def answer(value)
    { "0" => { "type" => "multiple_choice", "value" => value } }
  end

  test "routable? only single-pick types this pass" do
    assert LogicGraph.routable?({ "type" => "multiple_choice" })
    assert LogicGraph.routable?({ "type" => "yes_no" })
    assert LogicGraph.routable?({ "type" => "scenario" })
    refute LogicGraph.routable?({ "type" => "select_many" })
    refute LogicGraph.routable?({ "type" => "range" })
    refute LogicGraph.routable?({ "type" => "welcome_card" })
  end

  test "routing? needs a usable logic block" do
    refute LogicGraph.routing?({ "type" => "multiple_choice", "options" => %w[A B] })
    refute LogicGraph.routing?({ "type" => "multiple_choice", "logic" => {} })
    refute LogicGraph.routing?({ "type" => "multiple_choice", "logic" => { "routes" => [] } })
    # A logic block on a non-routable type never routes.
    refute LogicGraph.routing?({ "type" => "select_many",
                                 "logic" => { "default" => { "card" => "c_x" } } })
    assert LogicGraph.routing?({ "type" => "multiple_choice",
                                 "logic" => { "default" => { "card" => "c_x" } } })
    assert LogicGraph.routing?(hub_cards.first)
  end

  test "next_after: first matching route wins, canonical-label match" do
    hub = hub_cards.first
    assert_equal({ "card" => "c_uk" },  LogicGraph.next_after(hub, "UK"))
    assert_equal({ "end" => "uae_hub" }, LogicGraph.next_after(hub, "UAE"))
    assert_equal({ "card" => "c_us" },  LogicGraph.next_after(hub, "US"))
    # trailing/leading whitespace is normalised, like quiz/token matching.
    assert_equal({ "card" => "c_uk" }, LogicGraph.next_after(hub, "  UK "))
  end

  test "next_after: unmatched answer falls to default; no logic ⇒ nil" do
    hub = hub_cards.first
    assert_equal({ "card" => "c_generic" }, LogicGraph.next_after(hub, "Mars"))
    assert_equal({ "card" => "c_generic" }, LogicGraph.next_after(hub, nil))
    assert_nil LogicGraph.next_after({ "cid" => "c_p", "type" => "multiple_choice" }, "UK")
  end

  test "next_after: no default and no match ⇒ nil (linear)" do
    card = { "cid" => "c_a", "type" => "yes_no",
             "logic" => { "routes" => [
               { "match" => { "op" => "equals", "value" => "Yes" }, "to" => { "card" => "c_b" } }
             ] } }
    assert_equal({ "card" => "c_b" }, LogicGraph.next_after(card, "Yes"))
    assert_nil LogicGraph.next_after(card, "No")
  end

  test "cid_index maps cid to array position, skipping cid-less cards" do
    cards = hub_cards + [ { "type" => "open_ended", "text" => "no cid" } ]
    idx = LogicGraph.cid_index(cards)
    assert_equal 0, idx["c_hub"]
    assert_equal 3, idx["c_generic"]
    assert_equal 5, cards.length
    refute idx.value?(4) # the cid-less card is not indexed
  end

  test "next_index resolves cid targets, end targets and linear fall-through" do
    cards = hub_cards
    assert_equal 1, LogicGraph.next_index(cards, 0, answer("UK"))          # → c_uk
    assert_equal 2, LogicGraph.next_index(cards, 0, answer("US"))          # → c_us
    assert_equal({ end: "uae_hub" }, LogicGraph.next_index(cards, 0, answer("UAE")))
    assert_equal 3, LogicGraph.next_index(cards, 0, answer("Mars"))        # → default c_generic
    assert_equal 2, LogicGraph.next_index(cards, 1, answer("UK"))          # c_uk → linear next
    assert_nil LogicGraph.next_index(cards, 3, answer("UK"))               # last card → finish
  end

  test "next_index fails safe to linear when a cid target is dangling" do
    cards = [
      { "cid" => "c_a", "type" => "multiple_choice",
        "logic" => { "default" => { "card" => "c_missing" } } },
      { "cid" => "c_b", "type" => "open_ended" }
    ]
    assert_equal 1, LogicGraph.next_index(cards, 0, {}) # unknown cid ⇒ idx+1
  end

  test "resolve_path walks the taken route to an end or the deck end" do
    cards = hub_cards
    assert_equal [ 0, 1, 2, 3 ], LogicGraph.resolve_path(cards, answer("UK"))
    assert_equal [ 0, 2, 3 ],    LogicGraph.resolve_path(cards, answer("US"))
    assert_equal [ 0 ],          LogicGraph.resolve_path(cards, answer("UAE")) # ends immediately
    assert_equal [ 0, 3 ],       LogicGraph.resolve_path(cards, answer("Mars"))
  end

  test "resolve_path terminates on a self-looping graph (hop budget)" do
    cards = [
      { "cid" => "c_loop", "type" => "multiple_choice",
        "logic" => { "default" => { "card" => "c_loop" } } }
    ]
    path = LogicGraph.resolve_path(cards, {})
    assert_operator path.length, :<=, cards.length + 1
  end

  test "unreachable flags cards no edge reaches from the entry" do
    cards = [
      { "cid" => "c_0", "type" => "multiple_choice",
        "logic" => { "routes" => [
          { "match" => { "op" => "equals", "value" => "A" }, "to" => { "card" => "c_2" } }
        ], "default" => { "card" => "c_2" } } },
      { "cid" => "c_1", "type" => "open_ended" }, # only reachable by linear, but c_0 has a default so skips it
      { "cid" => "c_2", "type" => "open_ended" }
    ]
    assert_equal [ 1 ], LogicGraph.unreachable(cards)
  end

  test "longest_path counts the longest branch" do
    assert_equal 4, LogicGraph.longest_path(hub_cards) # 0 → c_uk(1) → c_us(2) → c_generic(3): 4 cards
    assert_equal 0, LogicGraph.longest_path([])
  end

  test "validate reports dangling targets, self loops and unreachable cards" do
    cards = [
      { "cid" => "c_0", "type" => "multiple_choice",
        "logic" => { "routes" => [
          { "match" => { "op" => "equals", "value" => "A" }, "to" => { "card" => "c_gone" } },
          { "match" => { "op" => "equals", "value" => "B" }, "to" => { "card" => "c_0" } },
          { "match" => { "op" => "equals", "value" => "C" }, "to" => { "end" => "nope" } }
        ] } },
      { "cid" => "c_1", "type" => "open_ended" }
    ]
    result = LogicGraph.validate(cards, %w[default uae_hub])
    dangling_targets = result[:dangling].map { |d| d[:target] }
    assert_includes dangling_targets, { "card" => "c_gone" }
    assert_includes dangling_targets, { "end" => "nope" } # end id not in the supplied set
    assert_equal [ 0 ], result[:self_loops]
  end

  test "no end-id validation when no end-screen set is supplied" do
    cards = [ { "cid" => "c_0", "type" => "multiple_choice",
               "logic" => { "default" => { "end" => "anything" } } } ]
    assert_empty LogicGraph.validate(cards)[:dangling]
  end

  # ── Per-card `next` flow pointer (the primitive first-class branches use) ─────

  # A UK lane of two PLAIN cards that chains via `next` and rejoins a common
  # tail: hub UK → c_uk1 → c_uk2 → c_common; everything else → c_common (skips
  # the lane). Indices: c_hub=0, c_uk1=1, c_uk2=2, c_common=3.
  def branch_cards
    [
      { "cid" => "c_hub", "type" => "multiple_choice", "text" => "Which hub?",
        "options" => %w[UK Other],
        "logic" => { "routes" => [
          { "match" => { "op" => "equals", "value" => "UK" }, "to" => { "card" => "c_uk1" } }
        ], "default" => { "card" => "c_common" } } },
      { "cid" => "c_uk1",   "type" => "open_ended", "text" => "UK Q1", "next" => { "card" => "c_uk2" } },
      { "cid" => "c_uk2",   "type" => "open_ended", "text" => "UK Q2", "next" => { "card" => "c_common" } },
      { "cid" => "c_common", "type" => "open_ended", "text" => "Common" }
    ]
  end

  test "card_next returns a valid target, else nil" do
    assert_equal({ "card" => "c_uk2" }, LogicGraph.card_next(branch_cards[1]))
    assert_nil LogicGraph.card_next(branch_cards[3])                 # no next ⇒ nil
    assert_nil LogicGraph.card_next({ "next" => { "card" => "" } })  # invalid target ⇒ nil
    assert_nil LogicGraph.card_next("not-a-hash")
  end

  test "next chains a plain card forward and rejoins, and siblings are skipped" do
    cards = branch_cards
    assert_equal 1, LogicGraph.next_index(cards, 0, answer("UK"))    # hub → c_uk1
    assert_equal 3, LogicGraph.next_index(cards, 0, answer("Other")) # default → c_common (skips lane)
    assert_equal 2, LogicGraph.next_index(cards, 1, {})              # c_uk1 next → c_uk2 (plain card!)
    assert_equal 3, LogicGraph.next_index(cards, 2, {})              # c_uk2 next → c_common (rejoin)
    assert_nil   LogicGraph.next_index(cards, 3, {})                 # common → finish
  end

  test "resolve_path walks a next-chained branch and rejoins the common tail" do
    cards = branch_cards
    assert_equal [ 0, 1, 2, 3 ], LogicGraph.resolve_path(cards, answer("UK"))
    assert_equal [ 0, 3 ],       LogicGraph.resolve_path(cards, answer("Other"))
  end

  test "answer routes and a valid default both outrank next" do
    cards = [
      { "cid" => "c0", "type" => "multiple_choice", "options" => %w[A B],
        "logic" => { "routes" => [ { "match" => { "op" => "equals", "value" => "A" }, "to" => { "card" => "c_a" } } ] },
        "next" => { "card" => "c_next" } },
      { "cid" => "c_a", "type" => "open_ended" },
      { "cid" => "c_next", "type" => "open_ended" }
    ]
    assert_equal 1, LogicGraph.next_index(cards, 0, answer("A")) # matching route wins over next
    assert_equal 2, LogicGraph.next_index(cards, 0, answer("B")) # unmatched, no default ⇒ next

    withdef = [ { "cid" => "c0", "type" => "multiple_choice",
                  "logic" => { "default" => { "card" => "c_def" } }, "next" => { "card" => "c_next" } },
                { "cid" => "c_def", "type" => "open_ended" },
                { "cid" => "c_next", "type" => "open_ended" } ]
    assert_equal 1, LogicGraph.next_index(withdef, 0, {}) # a valid default outranks next
  end

  test "next fails safe to linear when its target is dangling" do
    cards = [ { "cid" => "c0", "type" => "open_ended", "next" => { "card" => "c_gone" } },
              { "cid" => "c1", "type" => "open_ended" } ]
    assert_equal 1, LogicGraph.next_index(cards, 0, {}) # unknown cid ⇒ idx+1
  end

  test "edges_from includes a next edge and it replaces the linear edge" do
    cards = branch_cards
    assert_equal [ 2 ], LogicGraph.edges_from(cards, 1) # c_uk1 → c_uk2 only (no linear to c_uk2's slot)
    assert_includes LogicGraph.edges_from(cards, 0), 1  # hub reaches the lane
    assert_includes LogicGraph.edges_from(cards, 0), 3  # and the default/common
  end

  test "validate flags a dangling next on a plain (non-routing) card" do
    cards = [ { "cid" => "c0", "type" => "open_ended", "next" => { "card" => "c_gone" } } ]
    result = LogicGraph.validate(cards)
    assert_equal [ { "card" => "c_gone" } ], result[:dangling].map { |d| d[:target] }
  end
end
