require "set"

# Server-authoritative grading for Quiz Vertos.
#
# A question card opts into grading by carrying a `correct` key in the cards
# JSON, so a quiz Verto can freely mix graded questions and ordinary (ungraded)
# "measurement" questions. ALL grading happens here, on the server, from stored
# answers — the live player never receives the correct answers until it has
# committed an answer, so a score can't be gamed from the page source.
#
# The `correct` shape per card type mirrors the value the player records for
# that type (see player_controller.js `_read`):
#   multiple_choice / yes_no / select_one_grid / scenario → a canonical option label (String)
#   select_many / select_many_grid             → an array of canonical labels
#   tap_card                                    → { "statement" => "<response key>" }, any key on the card's scale (TapScales)
#   range / nps / rating                        → an Integer (step / value / stars)
#   open_ended                                  → an array of accepted answers
module QuizGrading
  module_function

  CHOICE_ONE  = %w[multiple_choice yes_no select_one_grid scenario].freeze
  CHOICE_MANY = %w[select_many select_many_grid].freeze
  SCALES      = %w[range nps rating].freeze

  # Does this card define a correct answer (and so get graded + scored)?
  def graded?(card)
    return false unless card.is_a?(Hash)
    return false unless CardTypes.question?(card["type"])
    correct_defined?(card["type"].to_s, card["correct"], card)
  end

  # The card indices (positions in the cards array — i.e. the answer keys) that
  # are graded. Used by the player view and the scores endpoint.
  def graded_indices(cards)
    Array(cards).each_index.select { |i| graded?(Array(cards)[i]) }
  end

  # Grade one stored answer value against a card's correct key. Returns true
  # only when the card is graded AND the value matches.
  def correct?(card, value)
    return false unless card.is_a?(Hash)
    type    = card["type"].to_s
    correct = card["correct"]
    return false unless correct_defined?(type, correct, card)

    case type
    when *CHOICE_ONE
      norm(value) == norm(correct)
    when *CHOICE_MANY
      to_label_set(value) == to_label_set(correct)
    when "tap_card"
      tap_correct?(correct, value, TapScales.keys_for(card))
    when *SCALES
      return false if blank_value?(value)
      (value.to_i - correct.to_i).abs <= card["correct_tolerance"].to_i
    when "open_ended"
      return false if value.to_s.strip.empty?
      accepted = Array(correct).map { |a| norm_text(a) }.reject(&:empty?)
      accepted.include?(norm_text(value))
    else
      false
    end
  end

  # Whole-response score from the stored answers hash (keyed by card index as a
  # string): { score:, max:, per_card: { idx => bool } }.
  def score(cards, answers)
    answers  = answers.is_a?(Hash) ? answers : {}
    per_card = {}
    points   = 0
    max      = 0
    Array(cards).each_with_index do |card, idx|
      next unless graded?(card)
      max += 1
      ok = correct?(card, answers[idx.to_s]&.dig("value"))
      per_card[idx] = ok
      points += 1 if ok
    end
    { score: points, max: max, per_card: per_card }
  end

  # Display-ready rendering of a card's correct answer, for the reveal shown
  # AFTER a player answers (never before). The player formats it for the UI.
  def correct_display(card)
    case card["type"].to_s
    when *CHOICE_MANY, "open_ended" then Array(card["correct"])
    when "tap_card"                 then (card["correct"].is_a?(Hash) ? card["correct"] : {})
    else card["correct"]
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  def correct_defined?(type, correct, card = nil)
    case type
    when *CHOICE_MANY, "open_ended"
      Array(correct).any? { |x| x.to_s.strip != "" }
    when "tap_card"
      scale = TapScales.keys_for(card)
      correct.is_a?(Hash) && correct.values.any? { |v| scale.include?(v.to_s) }
    when *SCALES
      !blank_value?(correct)
    else
      !correct.nil? && correct.to_s.strip != ""
    end
  end

  # `scale` is the card's own answer keys. It used to be the literal %w[yes no],
  # which was fine when those were the only answers a statement could be right
  # about; on a five-point scale the correct answer is as likely to be
  # "strongly_agree", and a hardcoded pair would grade every such card as
  # ungraded and quietly drop it out of the score.
  def tap_correct?(correct, value, scale)
    return false unless correct.is_a?(Hash) && value.is_a?(Hash)
    keys = correct.keys.select { |k| scale.include?(correct[k].to_s) }
    keys.any? && keys.all? { |k| value[k].to_s == correct[k].to_s }
  end

  def to_label_set(v)
    Array(v).map { |x| norm(x) }.reject(&:empty?).to_set
  end

  def blank_value?(v)
    v.nil? || (v.is_a?(String) && v.strip.empty?)
  end

  def norm(v)
    v.to_s.strip
  end

  def norm_text(v)
    v.to_s.strip.downcase.gsub(/\s+/, " ")
  end
end
