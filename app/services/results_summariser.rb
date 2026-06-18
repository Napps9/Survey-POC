class ResultsSummariser
  include AnthropicHelpers
  include FormatsResultsDigest

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
    @client = build_anthropic_client(api_key)
  end

  def call(survey:, aggregated:, total:, &block)
    return yield "Not enough responses to summarise yet." if total.zero?

    prompt = build_prompt(survey, aggregated, total)

    stream = @client.messages.stream_raw(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      system:     SYSTEM,
      messages:   [ { role: "user", content: prompt } ]
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
    results_digest(survey, aggregated, total)
  end
end
