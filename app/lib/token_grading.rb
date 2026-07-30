# Server-authoritative token accrual for tokenised Vertos.
#
# A question card opts into awarding tokens by carrying a `tokens` key
# (choice-shaped types and tap_card) or a `token_award` key (flat-award
# types) in the cards JSON, so a tokenised Verto can freely mix
# token-awarding cards with plain (unawarded) ones. ALL accrual happens here,
# on the server, from stored answers — a card's token config is public (it's
# rendered straight into the page, unlike a quiz's hidden `correct` answer),
# so the live player computes a running total client-side from that same
# config for instant feedback, but the server independently recomputes the
# cached total from the stored answers on every progress/submit, so a
# tampered client payload can never inflate what's actually saved.
#
# The `tokens` / `token_award` shape per card type mirrors the value the
# player records for that type (see player_controller.js `_read`):
#   multiple_choice / yes_no / select_one_grid / scenario → { "<canonical option>" => {token_id => amount} }, matched by the chosen label
#   select_many / select_many_grid             → same shape, summed across every chosen label
#   tap_card                                    → { "<statement>" => { "yes"|"no"|"unsure" => {token_id => amount} } }, matched by the chosen swipe direction
#   range / nps / rating / open_ended / prioritise → a flat `token_award` = {token_id => amount}, earned just for answering
#
# Choice-shaped cards (list/grid/yes-no) default to the per-option `tokens`
# shape above, but can opt into a flat `token_award` instead — awarded just
# for answering, regardless of which option was picked — by setting
# `token_award_mode: "completion"` on the card. See completion_award?.
module TokenGrading
  module_function

  CHOICE_ONE   = %w[multiple_choice yes_no select_one_grid scenario].freeze
  CHOICE_MANY  = %w[select_many select_many_grid].freeze
  CHOICE       = (CHOICE_ONE + CHOICE_MANY).freeze
  FLAT         = %w[range nps rating open_ended prioritise].freeze
  # Was a hand-copied list; now the canonical one, so a new non-answer card type
  # can't be added in one place and forgotten here.
  NON_QUESTION = CardTypes::NON_QUESTION_TYPES

  # Does this card award tokens (and so get counted)?
  #
  # "Off" used to be implicit — a card with all-zero amounts simply awarded
  # nothing, and the editor dropped zeros on save, so there was no way to tell a
  # deliberately-unawarded card from one a creator hadn't configured yet. An
  # explicit `tokens_enabled: false` says "this question doesn't award points",
  # and survives a save. Absent means enabled, so existing decks are unaffected.
  def awarding?(card)
    return false unless card.is_a?(Hash)
    return false if NON_QUESTION.include?(card["type"].to_s)
    return false if card["tokens_enabled"] == false
    any_amount?(config_for(card))
  end

  # The card indices (positions in the cards array — i.e. the answer keys)
  # that award tokens. Used by the editor hint and the totals computation.
  def awarding_indices(cards)
    Array(cards).each_index.select { |i| awarding?(Array(cards)[i]) }
  end

  # A choice-shaped card set to award a flat amount for completing the
  # question at all, rather than per chosen option.
  def completion_award?(card)
    CHOICE.include?(card["type"].to_s) && card["token_award_mode"].to_s == "completion"
  end

  # Tokens earned for one stored answer value, as {token_id => amount}.
  # Returns {} when the card doesn't award, or the value doesn't match.
  def earned(card, value)
    return {} unless card.is_a?(Hash)
    return flat_earned(card, value) if FLAT.include?(card["type"].to_s) || completion_award?(card)

    tokens = card["tokens"]
    case card["type"].to_s
    when *CHOICE_ONE
      tokens.is_a?(Hash) ? (tokens[norm(value)] || {}) : {}
    when *CHOICE_MANY
      return {} unless tokens.is_a?(Hash)
      sum_hashes(Array(value).map { |v| tokens[norm(v)] })
    when "tap_card"
      return {} unless tokens.is_a?(Hash) && value.is_a?(Hash)
      sum_hashes(value.map { |statement, dir| tokens.dig(statement, dir.to_s) })
    else
      {}
    end
  end

  # Whole-response totals from the stored answers hash (keyed by card index as
  # a string), seeded at 0 for every defined token type id so a type with no
  # hits still shows.
  def totals(cards, answers, token_type_ids)
    answers = answers.is_a?(Hash) ? answers : {}
    base = Array(token_type_ids).index_with { 0 }
    Array(cards).each_with_index do |card, idx|
      next unless awarding?(card)
      value = answers[idx.to_s]&.dig("value")
      earned(card, value).each { |k, v| base[k] = base[k] + v.to_i if base.key?(k) }
    end
    base
  end

  # ── internals ──────────────────────────────────────────────────────────────

  def config_for(card)
    (FLAT.include?(card["type"].to_s) || completion_award?(card)) ? card["token_award"] : card["tokens"]
  end

  def flat_earned(card, value)
    return {} if blank_value?(value)
    card["token_award"].is_a?(Hash) ? card["token_award"] : {}
  end

  def any_amount?(config)
    return false unless config.is_a?(Hash)
    config.values.any? { |v| v.is_a?(Hash) ? any_amount?(v) : v.to_i != 0 }
  end

  def sum_hashes(hashes)
    result = Hash.new(0)
    hashes.each { |h| h.is_a?(Hash) && h.each { |k, v| result[k] += v.to_i } }
    result
  end

  def norm(v)
    v.to_s.strip
  end

  def blank_value?(v)
    return true if v.nil?
    return v.strip.empty? if v.is_a?(String)
    return v.empty? if v.is_a?(Array)
    false
  end
end
