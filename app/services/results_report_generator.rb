# Generates a full, structured AI report from a Verto's aggregated results — the
# longer counterpart to ResultsSummariser's short insights blurb. Streams the
# report markdown (yielding chunks if a block is given) and returns the full
# markdown String, which the controller caches and renders to PDF / a Google Doc.
class ResultsReportGenerator
  include AnthropicHelpers
  include FormatsResultsDigest

  MODEL      = ClaudeModels::DEFAULT
  MAX_TOKENS = 3000

  SYSTEM = <<~PROMPT.freeze
    You are an expert survey analyst writing a polished results report for the
    survey's creator and their stakeholders. Produce a clear, well-structured
    report in GitHub-flavoured Markdown using these sections, in order:

    ## Executive summary
    Three to four sentences capturing the headline findings.

    ## Key findings
    A handful of concise bullet points, each citing specific figures
    (percentages, counts) where they're revealing.

    ## Question-by-question breakdown
    For each question a "### " heading with the question, then 1-3 sentences
    interpreting the distribution — what stands out and why it matters.

    ## Patterns & recommendations
    Notable cross-question patterns, then 2-4 concrete, actionable recommendations.

    Rules: ground every claim in the figures provided; be specific and concrete;
    never invent data that isn't present; keep a professional, lightly warm tone.
    Use Markdown headings (##/###), bold and bullet lists — but no tables and no
    code blocks.
  PROMPT

  def self.call(...) = new.call(...)

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  def call(survey:, aggregated:, total:, &block)
    return "Not enough responses yet to generate a report." if total.zero?

    prompt = results_digest(survey, aggregated, total)
    full   = +""

    stream = @client.messages.stream_raw(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      system:     SYSTEM,
      messages:   [ { role: "user", content: prompt } ]
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
        if delta.respond_to?(:type) && delta.type == :text_delta && delta.text
          full << delta.text
          block&.call(delta.text)
        end
      end
    end

    log_usage("ResultsReportGenerator", usage, model: MODEL, output_tokens: final_output)
    full
  end
end
