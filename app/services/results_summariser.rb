class ResultsSummariser
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 1024

  SYSTEM = <<~PROMPT.freeze
    You are an expert survey analyst. You will be given aggregated results from a
    survey and you must produce a concise, actionable insights summary for the
    survey creator. Write in plain English — no markdown headers, no bullet-point
    lists, no asterisks. Use short paragraphs (2-3 sentences each). Be specific:
    reference actual percentages and standout answers where they're revealing.
    Keep the whole summary under 200 words. Tone: clear, professional, slightly
    warm — like a thoughtful colleague sharing a debrief.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
  end

  def call(survey:, aggregated:, total:, &block)
    return yield "Not enough responses to summarise yet." if total.zero?

    prompt = build_prompt(survey, aggregated, total)

    stream = @client.messages.stream_raw(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      system:     SYSTEM,
      messages:   [{ role: "user", content: prompt }]
    )

    # message_start carries input/cache token counts; the final output_tokens
    # arrives later on message_delta.
    usage = nil
    final_output = nil
    stream.each do |raw_event|
      type = raw_event.type if raw_event.respond_to?(:type)
      case type
      when :message_start
        usage = raw_event.message.usage
      when :message_delta
        final_output = raw_event.usage.output_tokens if raw_event.respond_to?(:usage) && raw_event.usage
      when :content_block_delta
        delta = raw_event.delta
        yield delta.text if delta.respond_to?(:type) && delta.type == :text_delta && delta.text
      end
    end
    log_usage("ResultsSummariser", usage, model: MODEL, output_tokens: final_output)
  end

  private

  def build_prompt(survey, aggregated, total)
    lines = []
    lines << "Survey: \"#{survey.title}\""
    lines << "Theme: #{survey.theme}"
    lines << "Key insight goal: #{survey.key_insight}"
    lines << "Total responses: #{total}"
    lines << ""
    lines << "Per-question results:"
    lines << ""

    aggregated.each_with_index do |result, idx|
      type = result[:type]
      card = result[:card]
      next if type == "welcome_card"

      lines << "Q#{idx + 1} [#{type}]: #{card["text"]}"

      case type
      when "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid"
        counts = result[:counts]
        grand  = counts.values.sum.to_f
        grand  = 1.0 if grand.zero?
        counts.sort_by { |_, v| -v }.each do |label, count|
          pct = ((count / grand) * 100).round
          lines << "  #{label}: #{count} (#{pct}%)"
        end

      when "tap_card"
        result[:counts].each do |label, dirs|
          yes_c = dirs["yes"].to_i
          no_c  = dirs["no"].to_i
          tot   = (yes_c + no_c).to_f
          tot   = 1.0 if tot.zero?
          lines << "  \"#{label}\" → Yes #{yes_c} (#{((yes_c / tot) * 100).round}%), No #{no_c} (#{((no_c / tot) * 100).round}%)"
        end

      when "range"
        labels = Array(card["options"])
        grand  = result[:counts].values.sum.to_f
        grand  = 1.0 if grand.zero?
        result[:counts].sort.each do |step, count|
          label = labels[step] || "Step #{step + 1}"
          pct   = ((count / grand) * 100).round
          lines << "  #{label}: #{count} (#{pct}%)"
        end

      when "rating"
        lines << "  Average: #{result[:avg]} / 5 (#{result[:total]} responses)"
        result[:counts].sort.each do |star, count|
          lines << "  #{star} star#{"s" if star != 1}: #{count}"
        end

      when "open_ended"
        sample = result[:texts].first(5)
        lines << "  Sample responses (#{result[:total]} total):"
        sample.each { |t| lines << "    - \"#{t.truncate(120)}\"" }
      end

      lines << ""
    end

    lines.join("\n")
  end
end
