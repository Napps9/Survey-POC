module AggregatesSurveyResults
  extend ActiveSupport::Concern

  private

  def aggregate_results(cards, responses)
    cards.map.with_index do |card, idx|
      key  = idx.to_s
      type = card["type"].to_s
      vals = responses.filter_map { |r| r.answers[key]&.dig("value") }
      case type
      when "multiple_choice", "yes_no", "select_one_grid"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_s] += 1 } }
        { type:, card:, total: vals.size, counts: }
      when "select_many", "select_many_grid"
        counts = Hash.new(0).tap { |h| vals.each { |a| Array(a).each { |v| h[v.to_s] += 1 } } }
        { type:, card:, total: vals.size, counts: }
      when "tap_card"
        counts = {}
        vals.each { |obj| obj.each { |l, d| (counts[l] ||= { "yes" => 0, "no" => 0 })[d] += 1 } if obj.is_a?(Hash) }
        { type:, card:, total: vals.size, counts: }
      when "range"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_i] += 1 } }
        { type:, card:, total: vals.size, counts: }
      when "rating"
        counts = Hash.new(0).tap { |h| vals.each { |v| h[v.to_i] += 1 } }
        avg = vals.any? ? (vals.sum(&:to_f) / vals.size).round(1) : 0.0
        { type:, card:, total: vals.size, counts:, avg: }
      when "open_ended"
        { type:, card:, total: vals.size, texts: vals.map(&:to_s).reject(&:blank?) }
      when "static_page"
        { type:, card:, total: vals.size, completed: vals.count { |v| v == true } }
      else
        { type:, card:, total: responses.count, counts: {} }
      end
    end
  end
end
