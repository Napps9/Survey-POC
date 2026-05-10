class ResultsChat
  MODEL      = "claude-sonnet-4-6"
  MAX_TOKENS = 1024

  SYSTEM = <<~PROMPT.freeze
    You are Verto, an AI assistant embedded in Playverto — a survey platform.
    You help survey creators understand and explore their results through conversation.
    You have been given the full aggregated results for a specific survey.
    Answer questions about the data concisely and conversationally. Reference specific
    numbers and percentages when relevant. If asked for recommendations, be practical.
    Keep responses under 150 words unless the question genuinely requires more detail.
    Never use markdown formatting — plain text only, short paragraphs.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
  end

  def call(survey:, aggregated:, total:, messages:, &block)
    system_prompt = SYSTEM + "\n\n" + build_context(survey, aggregated, total)

    stream = @client.messages.stream_raw(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      system:     system_prompt,
      messages:   messages
    )

    stream.each do |raw_event|
      next unless raw_event.respond_to?(:type) && raw_event.type == :content_block_delta
      delta = raw_event.delta
      next unless delta.respond_to?(:type) && delta.type == :text_delta
      yield delta.text if delta.text
    end
  end

  private

  def build_context(survey, aggregated, total)
    lines = []
    lines << "SURVEY CONTEXT"
    lines << "Title: #{survey.title}"
    lines << "Theme: #{survey.theme}"
    lines << "Key insight goal: #{survey.key_insight}"
    lines << "Total completed responses: #{total}"
    lines << ""
    lines << "RESULTS DATA"

    aggregated.each_with_index do |result, idx|
      type = result[:type]
      card = result[:card]
      next if type == "welcome_card"

      lines << "Q#{idx + 1} [#{type}]: #{card["text"]}"

      case type
      when "multiple_choice", "yes_no", "select_one_grid", "select_many", "select_many_grid"
        grand = [result[:counts].values.sum.to_f, 1.0].max
        result[:counts].sort_by { |_, v| -v }.each do |label, count|
          lines << "  #{label}: #{count} (#{((count / grand) * 100).round}%)"
        end
      when "tap_card"
        result[:counts].each do |label, dirs|
          yes_c = dirs["yes"].to_i; no_c = dirs["no"].to_i
          tot   = [(yes_c + no_c).to_f, 1.0].max
          lines << "  \"#{label}\" → Yes #{yes_c} (#{((yes_c / tot) * 100).round}%), No #{no_c} (#{((no_c / tot) * 100).round}%)"
        end
      when "range"
        labels = Array(card["options"])
        grand  = [result[:counts].values.sum.to_f, 1.0].max
        result[:counts].sort.each do |step, count|
          lines << "  #{labels[step] || "Step #{step + 1}"}: #{count} (#{((count / grand) * 100).round}%)"
        end
      when "rating"
        lines << "  Average: #{result[:avg]} / 5 (#{result[:total]} responses)"
      when "open_ended"
        lines << "  #{result[:total]} text responses. Sample: #{result[:texts].first(3).map { |t| "\"#{t.truncate(80)}\"" }.join(", ")}"
      end
      lines << ""
    end

    lines.join("\n")
  end
end
