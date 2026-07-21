require "set"

# Answer-branching ("logic") resolution for Vertos.
#
# A single-pick question opts into branching by carrying a `logic` key in the
# cards JSON, so a logic Verto can freely mix routing questions with plain
# (linear) ones. Routing is the mirror image of the quiz/token pattern
# (QuizGrading / TokenGrading): pure functions over (cards, answers), used as
# the server-side test oracle and by the editor map. The live player resolves
# the same graph client-side in player_controller.js (see _resolveNext) — this
# module and that JS must agree.
#
# The `logic` shape (targets reference a card by its stable `cid`, or an end
# screen by id — never by array index):
#   {
#     "routes" => [
#       { "match" => { "op" => "equals", "value" => "<canonical option>" },
#         "to"    => { "card" => "c_9b2e10" } },   # or { "end" => "uk_hub" }
#       ...
#     ],
#     "default" => { "card" => "c_next01" }        # optional; omit ⇒ linear next
#   }
#
# `match.value` is the CANONICAL (primary-language) option label, keyed exactly
# like card["correct"] / card["tokens"], so routing aggregates across languages.
# `op` is "equals" only for now (single-pick). First matching route wins.
module LogicGraph
  module_function

  # Single-pick types that can carry routing logic this pass.
  ROUTABLE = %w[multiple_choice yes_no scenario].freeze

  # Can this card type carry routing logic at all?
  def routable?(card)
    card.is_a?(Hash) && ROUTABLE.include?(card["type"].to_s)
  end

  # Does this card actually route (a usable logic block with ≥1 valid route or
  # a valid default)? Absent/empty logic ⇒ false ⇒ pure linear flow.
  def routing?(card)
    return false unless routable?(card)
    logic = card["logic"]
    return false unless logic.is_a?(Hash)
    Array(logic["routes"]).any? { |r| valid_route?(r) } || valid_target?(logic["default"])
  end

  # The resolved target for one answer value on a card, or nil to fall through
  # to the linear next card. Returns the raw `to` hash ({ "card"=> } / { "end"=> }).
  def next_after(card, value)
    return nil unless routing?(card)
    logic = card["logic"]
    Array(logic["routes"]).each do |route|
      next unless valid_route?(route)
      return route["to"] if match?(route["match"], value)
    end
    valid_target?(logic["default"]) ? logic["default"] : nil
  end

  # A card's unconditional "next" flow override, honoured by ANY card type when
  # no answer route/default applies. Same target shape as a route:
  # { "card" => cid } | { "end" => id }. Absent/invalid ⇒ nil ⇒ linear next.
  # This is the primitive first-class branches compile to: it lets a lane of
  # cards (including plain, non-routable ones) chain forward and rejoin.
  def card_next(card)
    return nil unless card.is_a?(Hash)
    valid_target?(card["next"]) ? card["next"] : nil
  end

  # cid => array index for a deck (skips cards with no cid).
  def cid_index(cards)
    idx = {}
    Array(cards).each_with_index do |c, i|
      idx[c["cid"]] = i if c.is_a?(Hash) && c["cid"].to_s != ""
    end
    idx
  end

  # The next step after card `idx`, given the stored answers hash (keyed by card
  # index as a string). Returns an Integer next index, { end: id }, or nil when
  # the flow has run off the end (finish). A dangling `to.card` (unknown cid)
  # fails safe to the linear next card.
  def next_index(cards, idx, answers)
    cards  = Array(cards)
    card   = cards[idx]
    value  = answers.is_a?(Hash) ? answers[idx.to_s]&.dig("value") : nil
    target = card.is_a?(Hash) ? next_after(card, value) : nil
    # No answer route/default applied ⇒ the card's unconditional flow pointer
    # (any card type) takes over before the linear next. This is what lets a
    # branch of plain cards chain and rejoin the main flow.
    target = card_next(card) if target.nil?

    if target.is_a?(Hash)
      return { end: target["end"] } if target["end"].to_s != ""
      ci = cid_index(cards)[target["card"]]
      return ci if ci # dangling cid ⇒ fall through to linear
    end

    nxt = idx + 1
    nxt < cards.length ? nxt : nil
  end

  # The visited index sequence a respondent takes from `start` given their
  # answers, until an end screen or the deck end. A hop budget guarantees
  # termination on a malformed (looping) graph.
  def resolve_path(cards, answers, start: 0)
    cards  = Array(cards)
    path   = []
    idx    = start
    budget = cards.length + 1
    while idx.is_a?(Integer) && idx >= 0 && idx < cards.length && budget.positive?
      path << idx
      budget -= 1
      nxt = next_index(cards, idx, answers)
      break unless nxt.is_a?(Integer)
      idx = nxt
    end
    path
  end

  # The card indices reachable in one hop from card `i` over the static graph
  # (all route card-targets + default-or-linear). End targets are terminal and
  # excluded. Used by unreachable/longest_path and the editor map.
  def edges_from(cards, i, ci = nil)
    cards = Array(cards)
    ci  ||= cid_index(cards)
    card  = cards[i]
    outs  = []
    covered = false # a default / next (card or end) replaces the linear edge

    if card.is_a?(Hash) && routing?(card)
      logic = card["logic"]
      Array(logic["routes"]).each do |route|
        next unless valid_route?(route)
        target = route["to"]
        outs << ci[target["card"]] if target["card"].to_s != "" && ci.key?(target["card"])
      end
      default = logic["default"]
      if valid_target?(default)
        covered = true
        outs << ci[default["card"]] if default["card"].to_s != "" && ci.key?(default["card"])
      end
    end

    # No default ⇒ the card's unconditional `next` (any type) is the otherwise
    # edge; it too replaces the linear fall-through (mirrors next_index).
    unless covered
      nxt = card_next(card)
      if nxt
        covered = true
        outs << ci[nxt["card"]] if nxt["card"].to_s != "" && ci.key?(nxt["card"])
      end
    end

    outs << (i + 1) if !covered && (i + 1) < cards.length
    outs.uniq
  end

  # Cards no route/default reaches from the entry (index 0). Allowed — a parked
  # branch may be intentional — but surfaced as a warning on the map.
  def unreachable(cards)
    cards = Array(cards)
    return [] if cards.empty?
    ci        = cid_index(cards)
    reachable = Set.new
    stack     = [ 0 ]
    until stack.empty?
      i = stack.pop
      next if i.nil? || i.negative? || i >= cards.length || reachable.include?(i)
      reachable << i
      edges_from(cards, i, ci).each { |j| stack << j }
    end
    (0...cards.length).reject { |i| reachable.include?(i) }
  end

  # Longest path length in cards over the static graph, cycles broken (an upper
  # bound for the player's progress denominator).
  def longest_path(cards)
    cards = Array(cards)
    return 0 if cards.empty?
    ci       = cid_index(cards)
    memo     = {}
    visiting = Set.new
    dfs = lambda do |i|
      return 0 if i.nil? || i.negative? || i >= cards.length
      return memo[i] if memo.key?(i)
      return 0 if visiting.include?(i) # break cycle
      visiting << i
      best = edges_from(cards, i, ci).map { |j| dfs.call(j) }.max || 0
      visiting.delete(i)
      memo[i] = 1 + best
    end
    dfs.call(0)
  end

  # Validation warnings for the editor/map: dangling targets (unknown cid, or an
  # end id not in end_screen_ids when a set is supplied), zero-progress
  # self-loops (card → itself), and unreachable cards.
  def validate(cards, end_screen_ids = [])
    cards    = Array(cards)
    ci       = cid_index(cards)
    end_ids  = Array(end_screen_ids).map(&:to_s).to_set
    dangling = []
    loops    = []

    cards.each_with_index do |card, i|
      next unless card.is_a?(Hash)
      targets(card).each do |target|
        if target["card"].to_s != ""
          if !ci.key?(target["card"])
            dangling << { index: i, target: target }
          elsif ci[target["card"]] == i
            loops << i
          end
        elsif target["end"].to_s != "" && end_ids.any? && !end_ids.include?(target["end"].to_s)
          dangling << { index: i, target: target }
        end
      end
    end

    { dangling: dangling, self_loops: loops.uniq, unreachable: unreachable(cards) }
  end

  # Every target hash on a card (routes + default + the unconditional `next`),
  # for validation. Includes `next` for any card type, not just routing ones.
  def targets(card)
    return [] unless card.is_a?(Hash)
    out = []
    if card["logic"].is_a?(Hash)
      logic = card["logic"]
      out.concat(Array(logic["routes"]).filter_map { |r| r["to"] if valid_route?(r) })
      out << logic["default"] if valid_target?(logic["default"])
    end
    out << card["next"] if valid_target?(card["next"])
    out
  end

  # ── internals ──────────────────────────────────────────────────────────────

  def match?(matcher, value)
    return false unless matcher.is_a?(Hash)
    case matcher["op"].to_s
    when "equals" then norm(value) == norm(matcher["value"])
    else false
    end
  end

  def valid_target?(target)
    target.is_a?(Hash) && (target["card"].to_s != "" || target["end"].to_s != "")
  end

  def valid_route?(route)
    route.is_a?(Hash) && route["match"].is_a?(Hash) && valid_target?(route["to"])
  end

  def norm(value)
    value.to_s.strip
  end
end
