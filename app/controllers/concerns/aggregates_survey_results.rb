module AggregatesSurveyResults
  extend ActiveSupport::Concern

  private

  def aggregate_results(cards, responses)
    cards.map.with_index do |card, idx|
      key  = idx.to_s
      type = card["type"].to_s
      vals = responses.filter_map { |r| r.answers[key]&.dig("value") }
      # "Other" is a standalone free-text answer (its `value` is null, so it's
      # already excluded from the per-type distributions above/below).
      other_texts = responses.filter_map { |r| r.answers[key]&.dig("other").presence }
      other_count = other_texts.size
      base = { type:, card:, other_texts: }
      case type
      when "multiple_choice", "yes_no", "select_one_grid"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_s] += 1 } }
        counts["Other"] = other_count if other_count.positive?
        base.merge(total: vals.size + other_count, counts:)
      when "select_many", "select_many_grid"
        counts = Hash.new(0).tap { |h| vals.each { |a| Array(a).each { |v| h[v.to_s] += 1 } } }
        counts["Other"] = other_count if other_count.positive?
        base.merge(total: vals.size + other_count, counts:)
      when "tap_card"
        counts = {}
        vals.each { |obj| obj.each { |l, d| (counts[l] ||= { "yes" => 0, "no" => 0 })[d] += 1 } if obj.is_a?(Hash) }
        base.merge(total: vals.size + other_count, counts:)
      when "range", "nps"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_i] += 1 } }
        base.merge(total: vals.size + other_count, counts:)
      when "rating"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_i] += 1 } }
        avg = vals.any? ? (vals.sum(&:to_f) / vals.size).round(1) : 0.0
        base.merge(total: vals.size + other_count, counts:, avg:)
      when "open_ended"
        base.merge(total: vals.size + other_count, texts: vals.map(&:to_s).reject(&:blank?))
      else
        base.merge(total: responses.count, counts: {})
      end
    end
  end
end
