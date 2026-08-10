# Turns a question's free-text answers into themes with counts, plus the handful
# of quotes that can safely be shown to somebody outside the account.
#
# The existing OpenTextSummariser writes prose for the creator, who already holds
# the raw answers. This is a different job with a different risk: what it returns
# crosses an organisation boundary and gets quoted verbatim in front of strangers.
#
# So it does two things the summariser doesn't:
#
#   * counts. "412 of 2,041 talked about collective agency" is citable; "many
#     respondents mentioned..." is not. The tool schema requires a count for
#     every theme, and the counts are checked against the sample size here.
#   * an identifiability judgement per quote. QuoteRedactor has already removed
#     the shapes a regex can see; this is the pass for the ones it can't — the
#     only child in a class, the person who names their own street, the answer
#     whose detail is unique enough to place. When in doubt the model is told to
#     drop it, and a dropped quote costs nothing.
#
# Selecting quotes it never wrote is the whole design: the model picks from the
# supplied list by index, so a quote it hasn't been given cannot come back.
class OpenTextThemer
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 2000

  # How many answers go into one call. Not a sample any more — a BATCH size.
  #
  # This used to be the whole story: the first 250 answers were themed and the
  # rest were never read. That is not a sample, it is a head slice in whatever
  # order the rows were imported — on a paper file, whichever school happened to
  # be transcribed first — and the themes it produced described that school.
  # Every answer now goes through, in batches, and the batches are merged.
  BATCH_SIZE = 250

  # A ceiling on calls per question, so one enormous column cannot run away with
  # the indexing budget. When it bites, the batches are drawn EVENLY across the
  # whole column rather than off the top, and `sampled` says so in the result.
  MAX_BATCHES = ENV.fetch("ASK_VERTO_MAX_THEME_BATCHES", 40).to_i

  # Per question. A source card shows a few illustrative quotes, not a reader.
  MAX_QUOTES = 6

  SYSTEM = <<~PROMPT.freeze
    You are a survey analyst preparing open-text answers for a shared research
    corpus. What you produce will be read by researchers at OTHER organisations
    and quoted publicly, attributed to the survey but never to a person.

    Do two things.

    THEMES. Group the answers into 3-6 distinct themes. Give each a short
    neutral label (2-5 words) and an honest count of how many of the supplied
    answers belong to it. Counts must not exceed the number of answers given.
    Do not invent a theme to reach a number — three real themes beat six thin
    ones.

    QUOTES. Choose up to 6 answers, BY INDEX, that illustrate the themes well.
    A quote must be:
      - representative of a theme, not an outlier chosen for colour;
      - readable on its own, without the question in front of it;
      - impossible to trace to an individual.

    That last one is the one that matters. Reject a quote if it names a person,
    a school, an employer, a street or a small place; if it describes a role or
    circumstance rare enough to single someone out ("the only wheelchair user in
    my year"); if it recounts an incident that would be recognised locally; or
    if it discloses health, sexuality, immigration status or anything similar
    about the person writing it. You are not asked to be confident that a quote
    is safe — you are asked to drop it unless you are. Returning two quotes, or
    none, is a perfectly good answer.

    Never edit a quote. Select it by index or leave it out.

    Output via the emit_themes tool.
  PROMPT
  SYSTEM_WITH_SAFETY = (SYSTEM + PromptSafety::INSTRUCTION).freeze

  TOOL = {
    name: "emit_themes",
    description: "Return the themes found in the answers, and the indexes of quotes safe to publish.",
    input_schema: {
      type: "object",
      properties: {
        themes: {
          type: "array",
          description: "3-6 distinct themes, most common first.",
          items: {
            type: "object",
            properties: {
              label: { type: "string", description: "Short neutral label, 2-5 words." },
              count: { type: "integer", description: "How many of the supplied answers belong to this theme." }
            },
            required: %w[label count]
          }
        },
        quotes: {
          type: "array",
          description: "Up to 6 answers safe to publish verbatim, chosen by index.",
          items: {
            type: "object",
            properties: {
              index: { type: "integer", description: "0-based index of the answer in the supplied list." },
              theme: { type: "string", description: "The theme label this quote illustrates." }
            },
            required: %w[index theme]
          }
        }
      },
      required: %w[themes quotes]
    }
  }.freeze

  # The key is read lazily and its absence is not fatal.
  #
  # Themes and quotes are the enrichment; the counts are the point. A Verto
  # indexed where no key is configured stays fully citable for every closed
  # question and simply carries no themes — which is what index_quotes' own
  # rescue already says should happen when the call fails, and it could not
  # happen while the client was built in the constructor.
  def initialize(api_key: nil)
    @api_key = api_key || ENV["ANTHROPIC_API_KEY"]
  end

  def configured? = @api_key.present?

  def client = @client ||= build_anthropic_client(@api_key)

  # Returns { themes: [{ "label" =>, "count" => }], quotes: [{ body:, theme: }],
  #           read:, of:, sampled: }.
  #
  # `read` and `of` are the honest denominators: how many answers the themes
  # were actually derived from, and how many the question has. They travel with
  # the result because a theme count and a response count used to be handed to
  # Ask Verto side by side with nothing saying they were counted over different
  # numbers of people.
  #
  # `texts` must already have been through QuoteRedactor — this pass judges what
  # a regex cannot, it does not repeat what a regex already did.
  def call(question_text:, texts:)
    texts = Array(texts).map(&:to_s).reject(&:blank?)
    return empty(texts.size) unless configured?
    return empty(texts.size) if texts.size < CorpusEntry.min_sample_size

    batches = batches_for(texts)
    read    = batches.sum(&:size)
    merged  = Hash.new(0)
    quotes  = []

    batches.each do |batch|
      payload = theme_one(question_text, batch)
      next unless payload

      clean_themes(payload["themes"], batch.size).each { |t| merged[t["label"]] += t["count"] }
      quotes.concat(resolve_quotes(payload["quotes"], batch))
    end

    { themes: merged.sort_by { |_label, count| -count }.first(6).map { |label, count| { "label" => label, "count" => count } },
      # Spread the quotes across the batches rather than taking the first
      # batch's six, so they illustrate the column and not its opening pages.
      quotes:  quotes.uniq { |q| q[:body] }.first(MAX_QUOTES),
      read: read, of: texts.size, sampled: read < texts.size }
  end

  private

  def empty(total) = { themes: [], quotes: [], read: 0, of: total, sampled: false }

  # Consecutive batches when the whole column fits inside MAX_BATCHES; an even
  # stride across the whole column when it does not. Either way every part of
  # the column is represented — the one thing a head slice never managed.
  def batches_for(texts)
    whole = texts.each_slice(BATCH_SIZE).to_a
    return whole if whole.size <= MAX_BATCHES

    stride = whole.size / MAX_BATCHES.to_f
    (0...MAX_BATCHES).map { |i| whole[(i * stride).floor] }
  end

  def theme_one(question_text, batch)
    response = client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      SYSTEM_WITH_SAFETY,
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "emit_themes" },
      messages:    [ { role: "user", content: build_prompt(question_text, batch) } ]
    )

    log_usage("OpenTextThemer", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    block && deep_stringify(input_of(block))
  end

  def build_prompt(question_text, sample)
    lines = [ "Question: \"#{question_text}\"", "",
              "Answers (#{sample.size} shown, indexed from 0):" ]
    sample.each_with_index { |t, i| lines << "[#{i}] #{PromptSafety.quote(t, limit: 300)}" }
    lines.join("\n")
  end

  # A theme count above the sample size is a model error, and an uncorrected one
  # would be cited as fact. Clamp rather than drop: the theme is real even when
  # the arithmetic slipped.
  def clean_themes(themes, sample_size)
    Array(themes).filter_map do |theme|
      label = theme["label"].to_s.strip
      next if label.empty?

      { "label" => label, "count" => theme["count"].to_i.clamp(0, sample_size) }
    end.first(6)
  end

  # Indexes back into the answers WE supplied. An index outside the list is
  # dropped — that is the guarantee that a quote is a respondent's own words and
  # not the model's.
  def resolve_quotes(quotes, sample)
    Array(quotes).filter_map do |quote|
      idx = quote["index"]
      next unless idx.is_a?(Integer) && idx >= 0 && idx < sample.size

      { body: sample[idx], theme: quote["theme"].to_s.strip.presence }
    end.uniq { |q| q[:body] }.first(MAX_QUOTES)
  end
end
