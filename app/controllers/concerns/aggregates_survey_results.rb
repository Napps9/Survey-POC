module AggregatesSurveyResults
  extend ActiveSupport::Concern

  private

  # Builds the per-card results distribution. Iterates the responses ONCE
  # (batched, answers-column only, for AR relations) and accumulates every
  # card's tallies in the same pass — instead of re-enumerating the full
  # response set twice per card, which held every Response object resident in
  # memory for the whole loop. Output is identical to the previous per-card
  # filter_map implementation.
  #
  # `responses` may be an ActiveRecord relation (the common case) or a plain
  # array of Response objects (e.g. CommonQuestionAggregator builds in-memory
  # Response.new rows) — each_response handles both.
  def aggregate_results(cards, responses)
    types  = cards.map { |card| card["type"].to_s }
    states = cards.each_with_index.map { |card, i| new_card_state(types[i], card) }
    total  = 0

    each_response(responses) do |answers|
      total += 1
      cards.each_index do |idx|
        a = answers[idx.to_s]
        next unless a.is_a?(Hash)

        st    = states[idx]
        value = a["value"]
        # Mirror the old `filter_map { ...dig("value") }`: drop nil/false only
        # (so 0 and "" are kept, exactly as before).
        unless value.nil? || value == false
          st[:value_count] += 1
          accumulate_value(st, types[idx], value)
        end
        other = a["other"]
        st[:other_texts] << other if other.respond_to?(:presence) && other.presence
      end
    end

    cards.map.with_index { |card, idx| finalize_card(card, types[idx], states[idx], total) }
  end

  # Yield each response's answers Hash. For relations, load only id+answers in
  # batches so the whole set is never resident at once; for arrays (in-memory
  # Response objects), iterate directly.
  def each_response(responses)
    if responses.respond_to?(:find_each)
      responses.reorder(nil).select(:id, :answers).find_each(batch_size: 500) do |r|
        yield(r.answers || {})
      end
    else
      responses.each { |r| yield(r.answers || {}) }
    end
  end

  # A tap card carries its own answer keys into the state, because they are the
  # only thing that says what an answer to THIS card can be — a five-point scale
  # and the historic yes/unsure/no are both tap cards, and a tally seeded with
  # the wrong set drops every answer it has no slot for.
  def new_card_state(type, card = nil)
    st = { value_count: 0, other_texts: [], counts: Hash.new(0), texts: [], sum: 0.0 }
    st[:response_keys] = TapScales.keys_for(card) if type == "tap_card"
    st
  end

  def accumulate_value(st, type, value)
    case type
    when "multiple_choice", "yes_no", "select_one_grid", "scenario"
      st[:counts][value.to_s] += 1
    when "select_many", "select_many_grid"
      Array(value).each { |v| st[:counts][v.to_s] += 1 }
    when "prioritise"
      # value is the ordered list, highest priority first. Bank each option's
      # 1-based rank so we can average positions later (lower mean = higher
      # priority).
      Array(value).each_with_index { |label, i| st[:counts][label.to_s] += (i + 1) }
    when "tap_card"
      if value.is_a?(Hash)
        keys = st[:response_keys] || TapScales.keys_for(nil)
        value.each do |label, dir|
          # st[:counts] has a 0 default (for the scalar types), so guard on
          # is_a?(Hash) rather than ||= when nesting per-statement tallies.
          # Seeded from the card's own scale so every response shows on the
          # results page, including the ones nobody picked.
          st[:counts][label] = keys.index_with { 0 } unless st[:counts][label].is_a?(Hash)
          st[:counts][label][dir.to_s] += 1 if st[:counts][label].key?(dir.to_s)
        end
      end
    when "range", "nps"
      st[:counts][value.to_i] += 1
    when "rating"
      st[:counts][value.to_i] += 1
      st[:sum] += value.to_f
    when "open_ended"
      str = value.to_s
      st[:texts] << str unless str.blank?
    when "contact_form"
      # The submitted field-object, whole — the results view renders these as
      # a lead table rather than counting anything.
      st[:texts] << value if value.is_a?(Hash) && value.present?
    end
  end

  def finalize_card(card, type, st, total_responses)
    other_count = st[:other_texts].size
    base = { type:, card:, other_texts: st[:other_texts] }

    case type
    when "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid", "scenario"
      counts = st[:counts]
      counts["Other"] = other_count if other_count.positive?
      base.merge(total: st[:value_count] + other_count, counts:)
    when "tap_card"
      base.merge(total: st[:value_count] + other_count, counts: st[:counts])
    when "prioritise"
      # counts[label] = sum of ranks; total = responders, so mean rank =
      # counts[label] / total. Lower mean = higher priority.
      base.merge(total: st[:value_count], counts: st[:counts])
    when "range", "nps"
      base.merge(total: st[:value_count] + other_count, counts: st[:counts])
    when "rating"
      avg = st[:value_count].positive? ? (st[:sum] / st[:value_count]).round(1) : 0.0
      base.merge(total: st[:value_count] + other_count, counts: st[:counts], avg:)
    when "open_ended"
      base.merge(total: st[:value_count] + other_count, texts: st[:texts])
    when "contact_form"
      base.merge(total: st[:value_count], entries: st[:texts])
    else
      base.merge(total: total_responses, counts: {})
    end
  end
end
