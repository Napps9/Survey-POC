class OpenTextSummariser
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 400
  MAX_ANSWERS_IN_PROMPT = 200

  SYSTEM = <<~PROMPT.freeze
    You are an expert survey analyst. You will be given one open-text survey
    question and the free-text answers from one respondent segment (e.g. a
    region). Summarise the key themes in plain English — no markdown, no
    bullet-point lists, no asterisks. 2-4 short sentences. Reference specific
    recurring ideas or a standout quote where it's revealing. If the answers
    are too few or too thin to summarise meaningfully, say so plainly rather
    than inventing a theme.
  PROMPT
  SYSTEM_WITH_SAFETY = (SYSTEM + PromptSafety::INSTRUCTION).freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  def call(question:, texts:, &block)
    texts = Array(texts).map(&:to_s).reject(&:blank?)
    return yield "Not enough responses to summarise yet." if texts.empty?

    stream = @client.messages.stream_raw(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      system:     SYSTEM_WITH_SAFETY,
      messages:   [ { role: "user", content: build_prompt(question, texts) } ]
    )

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
    log_usage("OpenTextSummariser", usage, model: MODEL, output_tokens: final_output)
  end

  private

  def build_prompt(question, texts)
    sample = texts.first(MAX_ANSWERS_IN_PROMPT)
    lines  = [ "Question: \"#{question}\"", "", "Answers (#{texts.size} total):" ]
    sample.each { |t| lines << "- #{PromptSafety.quote(t, limit: 300)}" }
    lines.join("\n")
  end
end
