# Generates a full, structured AI report from a Verto's aggregated results — the
# longer counterpart to ResultsSummariser's short insights blurb. Streams the
# report markdown (yielding chunks if a block is given) and returns the full
# markdown String, which the controller caches and renders to PDF / a Google Doc.
class ResultsReportGenerator
  include AnthropicHelpers
  include FormatsResultsDigest

  MODEL      = ClaudeModels::DEFAULT
  MAX_TOKENS = 3000

  # The creator's requested report length → a hard output-token ceiling plus a
  # word-budget instruction the prompt cites, so "generate a report" can't run
  # to a dozen generic pages.
  LENGTHS = {
    "short"    => { max_tokens: 1200, words: "no more than about 400 words — roughly one page" },
    "standard" => { max_tokens: 2500, words: "roughly 600–900 words" },
    "detailed" => { max_tokens: 4000, words: "up to about 1,500 words" }
  }.freeze
  DEFAULT_LENGTH = "standard".freeze

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
    code blocks. Honour the report brief at the top of the input: write for its
    stated goal and audience, and stay within its requested length — a shorter,
    sharper report beats a longer one. Under a tight length budget, compress the
    question-by-question section rather than the summary or recommendations.
  PROMPT
  SYSTEM_WITH_SAFETY = (SYSTEM + PromptSafety::INSTRUCTION).freeze

  def self.call(...) = new.call(...)

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  def call(survey:, aggregated:, total:, brief: {}, &block)
    return "Not enough responses yet to generate a report." if total.zero?

    brief  = (brief || {}).transform_keys(&:to_s)
    length = LENGTHS[brief["length"]] || LENGTHS[DEFAULT_LENGTH]
    prompt = "#{brief_block(brief, length)}\n\n#{results_digest(survey, aggregated, total)}"
    full   = +""

    stream = @client.messages.stream_raw(
      model:      MODEL,
      max_tokens: length[:max_tokens],
      system:     SYSTEM_WITH_SAFETY,
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

  private

  # The creator-supplied brief, rendered ahead of the results digest. Length is
  # always stated (falling back to the standard budget) so the model has an
  # explicit word target even with an empty brief.
  def brief_block(brief, length)
    lines = [ "Report brief from the creator:" ]
    lines << "- Goal of this report: #{brief["goal"]}"  if brief["goal"].present?
    lines << "- Audience: #{brief["audience"]}"         if brief["audience"].present?
    lines << "- Requested length: #{length[:words]}"
    lines.join("\n")
  end
end
