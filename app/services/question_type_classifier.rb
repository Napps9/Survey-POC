require "anthropic"

# Given a list of pre-written question texts, asks Claude to pick the
# best-fitting Verto card type for each and (when the type needs them)
# supply options. The question wording is preserved verbatim — the model is
# instructed not to reword, and a Ruby alignment step swaps the original
# text back in if the model deviates.
#
# Extracted from PdfQuestionImporter so the same classification logic can
# back both the PDF-import flow and the Common Questions creation flow,
# without forcing the latter to fabricate a synthetic PDF.
class QuestionTypeClassifier
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 4096

  # Mirrors PdfQuestionImporter's list — yes_no's two options are implicit
  # and welcome_card / open_ended take none.
  TYPES_WITHOUT_OPTIONS = %w[welcome_card open_ended yes_no].freeze

  TOOL = {
    name: "classify_questions",
    description: "For each input question, pick the best-fitting Verto answer type and supply its options when needed. Echo each question's text back verbatim and preserve input order.",
    input_schema: {
      type: "object",
      properties: {
        classifications: {
          type: "array",
          description: "One entry per input question, in the same order.",
          items: {
            type: "object",
            properties: {
              text: { type: "string", description: "The input question text, echoed verbatim. Do not reword." },
              type: { type: "string", enum: SurveyGenerator::CARD_TYPES, description: "Best-fitting answer type." },
              description: { type: "string", description: "Optional sub-text. Shares the 100-char budget with text." },
              options: {
                type: "array",
                items: { type: "string", description: "Each option label within its type's character budget (see the design rules)." },
                description: <<~DESC
                  Required for: multiple_choice, select_many, select_one_grid,
                  select_many_grid, prioritise, tap_card, range, rating, nps.
                  Generate sensible, mutually-exclusive options that satisfy the bounds:
                  - multiple_choice / select_many: ODD count — 3 or 5 options, each <= 30 chars
                  - select_one_grid / select_many_grid: EVEN count, 4 to 10 including any
                    "Other", each label <= 20 chars
                  - prioritise: 4 or 5 options (4 ideal), each <= 30 chars
                  - tap_card: 5 to 8 statements covering negative, neutral and positive
                    sentiments in that order, each <= 40 chars
                  - range: ODD count only (3 or 5, 5 ideal — never 4) with a genuinely
                    neutral middle label
                  - rating: 3 to 5 points (5 ideal), ONE label per point, never more than 5
                  - nps: EXACTLY 11 numeric labels, "0" through "10" — no word labels
                DESC
              },
              allow_other: { type: "boolean", description: "Set true only if the question explicitly invites a free-text 'Other'." }
            },
            required: %w[text type]
          }
        }
      },
      required: %w[classifications]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You assign Verto answer types to a list of pre-written questions. Your job
    is NOT to redesign anyone's survey — only to (1) preserve each question's
    wording verbatim and (2) pick the single best-fitting answer type from the
    catalogue below, supplying options where the type requires them.

    Per-card rules (every classification must satisfy these):

    #{SurveyGenerator::CARD_RULES}

    Choosing the best-fitting type:
    - "Choose one" / single-pick -> select_one_grid by default; fall back to
      multiple_choice when option labels are long (over ~14 chars).
    - "Choose all that apply" / multi-pick -> select_many_grid by default; fall
      back to select_many for long labels.
    - An explicit ranking question ("In what order...", "Rank these...") ->
      prioritise (4 or 5 options, 4 ideal).
    - A 1-5 quality/satisfaction rating ("How would you rate...") -> rating
      (one label per point).
    - An emotion/agreement/"how often" scale, or any scale where an engaging
      reactive animation adds value -> range (odd count, 3 or 5 points, with
      a genuine neutral middle).
    - Likelihood-to-recommend / NPS or a plain 0-10 sentiment scale -> nps
      (EXACTLY 11 numeric labels "0"-"10", a plain vertical slider).
    - A single topic probed from several angles (or an explicit
      negative/neutral/positive statement set) -> tap_card (5 to 8 statements,
      in negative -> neutral -> positive order, each <= 40 chars).
    - A strict binary gate -> yes_no (use sparingly).
    - An open, qualitative "tell us..." / "why..." question with no fixed
      answers -> open_ended.
    - NEVER emit a welcome_card — these are user-authored questions only.

    When in doubt between a grid and a list, prefer the grid. When in doubt
    between rating, range and nps, pick the one whose framing matches the
    question (stars -> rating; emotion/agreement slider -> range;
    likelihood/recommendation -> nps).

    CRITICAL: Echo each input question's `text` back exactly as supplied. Do
    not reword, translate, or punctuate-tidy. Preserve input order.

    Output via the classify_questions tool.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # questions: Array<String>. Returns Array<Hash> aligned 1:1 with input,
  # each shaped like a Verto card (string keys: "type", "text", optional
  # "description", "options", "allow_other"). Anything malformed or for an
  # unknown type is dropped — callers can detect a short return.
  def call(questions:, locale: SupportedLocales::DEFAULT)
    inputs = Array(questions).map { |q| q.to_s.strip }.reject(&:empty?)
    return [] if inputs.empty?

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      [ { type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } } ],
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "classify_questions" },
      messages: [ {
        role: "user",
        content: "Target language for any generated option labels: #{locale}.\n" \
                 "Classify each question below. Echo each `text` back verbatim.\n\n" \
                 "Questions:\n" \
                 "#{JSON.pretty_generate(inputs)}"
      } ]
    )

    log_usage("QuestionTypeClassifier", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    raw = Array(deep_stringify(input_of(block))["classifications"])
    aligned = align_to_inputs(raw, inputs)
    normalize_cards(aligned)
  end

  # Same normalization the editor/player rely on — keep only well-formed
  # cards of a generatable type, clean options, enforce structural caps.
  # Public so other callers (PdfQuestionImporter) can reuse it.
  def normalize_cards(cards)
    allowed = SurveyGenerator.generatable_types
    Array(cards).filter_map do |card|
      next unless card.is_a?(Hash)
      type = card["type"].to_s
      text = card["text"].to_s.strip
      next if !allowed.include?(type) || text.empty?

      out = { "type" => type, "text" => text }
      out["description"] = card["description"].to_s.strip if card["description"].to_s.strip.present?

      options = Array(card["options"]).map { |o| o.to_s.strip }.reject(&:empty?)
      options = options.first(SurveyGenerator::TAP_CARD_MAX_STATEMENTS) if type == "tap_card"
      out["options"] = options unless TYPES_WITHOUT_OPTIONS.include?(type) || options.empty?

      out["allow_other"] = true if card["allow_other"] == true
      out
    end
  end

  private

  # Walk inputs in order. For each, take the next emitted classification (if
  # any) and force its `text` back to the original input. Extras the model
  # emitted beyond the input length are dropped; misses leave a nil slot
  # that `normalize_cards` will filter out as malformed.
  def align_to_inputs(raw, inputs)
    inputs.each_with_index.map do |original_text, i|
      entry = raw[i]
      next nil unless entry.is_a?(Hash)
      entry.merge("text" => original_text)
    end
  end
end
