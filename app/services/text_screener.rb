require "anthropic"

# Classifies held free-text answers (HeldText) with Claude, in batches.
#
# One call per batch, one verdict per text, reported through a forced tool
# call so the answer is structured or absent — never prose to parse. The
# service returns verdicts; ScreenHeldTextsJob decides what to do with them
# (release, remove, refer to a person) so the policy lives in one place and
# this stays a classifier.
#
# Never raises. A transport error, a refusal, or a response with no tool block
# after one retry all come back as { ok: false, error: } — the job treats every
# one of those as "not screened", which leaves the text held. The screen can
# fail; it cannot fail open.
class TextScreener
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 2048
  # Longer than any card's free-text limit allows, so nothing is cut; bounded
  # so a crafted payload can't make one text cost a page of tokens.
  TEXT_LIMIT = 2_500

  CATEGORIES = %w[clean identifying profanity hate sexual threat spam safeguarding].freeze
  # The categories the job may act on without a person, when certain enough.
  VIOLATIONS = %w[identifying profanity hate sexual threat spam].freeze

  TOOL = {
    name: "report_text_screen",
    description: "Report exactly one verdict for every numbered respondent text.",
    input_schema: {
      type: "object",
      properties: {
        verdicts: {
          type: "array",
          items: {
            type: "object",
            properties: {
              index:     { type: "integer", description: "The text's number, exactly as given." },
              category:  { type: "string",  enum: CATEGORIES },
              certainty: { type: "number",  minimum: 0, maximum: 1,
                           description: "How sure you are of the category, 0.0-1.0. Confidence, not severity." },
              note:      { type: "string",  description: "When not clean: a few words on what was found. Do not quote the text." }
            },
            required: %w[index category certainty]
          }
        }
      },
      required: %w[verdicts]
    }
  }.freeze

  Verdict = Struct.new(:category, :certainty, :note, keyword_init: true)

  def self.configured?
    ENV["ANTHROPIC_API_KEY"].present?
  end

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # items: [{ index: Integer, text: String, question: String|nil }, ...]
  #
  # Returns { ok: true, verdicts: { index => Verdict } } — an index the model
  # skipped is simply absent — or { ok: false, error: String }.
  def call(items, audience_age: nil)
    items = Array(items)
    return { ok: true, verdicts: {} } if items.empty?

    verdicts = perform_call(items, audience_age) || perform_call(items, audience_age)
    return { ok: false, error: "no verdict block in response" } unless verdicts

    { ok: true, verdicts: verdicts }
  rescue => e
    Rails.logger.warn("[TextScreener] #{e.class}: #{e.message}")
    { ok: false, error: "#{e.class}: #{e.message}".first(200) }
  end

  private

  # One Claude call. Returns the parsed verdicts keyed by index, or nil when
  # the response carries no tool_use block (a hedge or refusal, not a verdict).
  def perform_call(items, audience_age)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      system_prompt(audience_age),
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: TOOL[:name] },
      messages:    [ { role: "user", content: user_message(items) } ],
      request_options: anthropic_request_options
    )
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    log_usage("TextScreener", response.usage, model: MODEL, ms: ms)

    block = Array(response.content).find { |b| tool_use?(b) }
    unless block
      Rails.logger.warn("[TextScreener] no tool_use block in response")
      return nil
    end

    parse_verdicts(deep_stringify(input_of(block)), items.map { |i| i[:index] })
  end

  # Only well-formed verdicts for indices we asked about survive. A category
  # outside the enum or an index we never sent is dropped rather than guessed
  # at — a dropped verdict leaves the text held, which is the safe direction.
  def parse_verdicts(input, valid_indices)
    Array(input["verdicts"]).each_with_object({}) do |v, out|
      next unless v.is_a?(Hash)

      index    = Integer(v["index"], exception: false)
      category = v["category"].to_s
      next unless index && valid_indices.include?(index) && CATEGORIES.include?(category)

      certainty = Float(v["certainty"], exception: false)
      next if certainty.nil?

      out[index] = Verdict.new(category: category,
                               certainty: certainty.clamp(0.0, 1.0),
                               note: v["note"].to_s.strip.first(300).presence)
    end
  end

  def system_prompt(audience_age)
    audience = audience_age.to_s.strip.presence || "not stated"
    <<~SYS + PromptSafety::INSTRUCTION
      You are the content moderator for VertoNow, a public survey platform.
      Respondents — often young people, sometimes children — type short
      free-text answers from a public link. Before any answer is shown to the
      organisation running the survey, you classify it. The survey's audience
      is: #{audience}.

      For EACH numbered text report exactly one category, and how certain you
      are of that category (0.0–1.0; confidence, not severity):

      - clean: an ordinary answer to the question. Strong opinions, criticism,
        slang, mild rudeness, mentions of public figures or brands, nonsense
        or keyboard-mashing, and answers in any language are all clean.
      - identifying: could identify a real private person — the writer or
        someone else. A full name; a home, school or work address; a named
        school, class, team or employer with enough detail to single a person
        out; a username, ID number, or exact date of birth. A first name alone,
        or "my mum" / "my teacher", is NOT identifying.
      - profanity: gratuitous obscenity or slurs, not merely a rude word in an
        otherwise ordinary answer.
      - hate: attacks or demeans people for a protected characteristic.
      - sexual: sexual content of any kind, and anything sexual concerning a minor.
      - threat: a threat, or incitement, of violence against another person.
      - spam: advertising, solicitation, or text plainly unrelated to any
        survey — not merely a short or lazy answer.
      - safeguarding: the writer discloses abuse, neglect, self-harm, suicidal
        thoughts, exploitation, or being in danger — anything a teacher would
        be required to act on. Report this whenever it is plausible, even at
        low certainty: a person will read it.

      Judge each text on its own. The question wording is context only. When
      torn between clean and any other category, prefer the other category
      with a lower certainty rather than clean.
    SYS
  end

  def user_message(items)
    lines = items.map do |item|
      question = item[:question].to_s.strip.presence
      header   = "##{item[:index]}" + (question ? " — Question: #{question.first(200).inspect}" : "")
      "#{header}\n#{PromptSafety.quote(item[:text], limit: TEXT_LIMIT)}"
    end
    "Screen these #{items.size} respondent texts.\n\n#{lines.join("\n\n")}"
  end
end
