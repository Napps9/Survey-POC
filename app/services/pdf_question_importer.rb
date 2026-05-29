require "anthropic"

# Imports a user's prewritten questions from an uploaded PDF and assigns each
# one the best-matching Verto card type, following the same per-card design
# rules as SurveyGenerator.
#
# Unlike SurveyGenerator (which invents 10-15 questions from a brief), this
# keeps the user's questions verbatim and only chooses the answer type — and,
# when the chosen type needs options the PDF didn't provide, fills in sensible
# ones. The Anthropic SDK reads the PDF natively via a base64 `document`
# content block, so no PDF-parsing gem is required.
class PdfQuestionImporter
  include AnthropicHelpers

  MODEL      = ClaudeModels::DEFAULT
  MAX_TOKENS = 8192

  # Types that never carry a free-form options list. yes_no's two options are
  # implicit; welcome_card/open_ended take no options at all.
  TYPES_WITHOUT_OPTIONS = %w[welcome_card open_ended yes_no].freeze

  TOOL = {
    name: "emit_survey",
    description: "Emit the questions extracted from the PDF, each mapped to the best-fitting Verto answer type.",
    input_schema: {
      type: "object",
      properties: {
        title:       { type: "string", description: "Short Verto title inferred from the PDF (falls back to a generic title)." },
        description: { type: "string", description: "Optional 1-2 sentence intro shown to respondents." },
        cards: {
          type: "array",
          description: "One card per question found in the PDF, in document order. Do not invent or drop questions.",
          items: {
            type: "object",
            properties: {
              type: { type: "string", enum: SurveyGenerator::CARD_TYPES, description: "The best-fitting answer type for this question." },
              text: { type: "string", description: "The question text, kept close to the PDF wording. Target 50-70 chars; 100 hard max (text + any description <= 100)." },
              description: { type: "string", description: "Optional sub-text under the question. Shares the question's 100-char budget." },
              options: {
                type: "array",
                items: { type: "string", description: "Each option <= 20 chars in select-one lists." },
                description: <<~DESC
                  Required for: multiple_choice, select_many, select_one_grid,
                  select_many_grid, tap_card, range, rating, nps. Use the options
                  written in the PDF when present; otherwise generate sensible,
                  mutually-exclusive options that satisfy the bounds:
                  - multiple_choice / select_many: 3 to 5 options, each <= 20 chars
                  - select_one_grid / select_many_grid: EVEN count, 4 to 10 including any "Other"
                  - tap_card: EXACTLY 3 cards (negative / neutral / positive sentiments)
                  - range / rating: 3 to 5 points, never more than 5
                  - nps: EXACTLY 5 points, each label <= 20 chars
                DESC
              },
              allow_other: { type: "boolean", description: "Set true only if the question explicitly offers a free-text 'Other'." }
            },
            required: %w[type text]
          }
        }
      },
      required: %w[title cards]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You convert a user's prewritten questionnaire (supplied as a PDF) into a
    Verto. Your job is NOT to redesign their survey — it is to:

    1. Extract EVERY question in the PDF, in the order they appear. Do not
       invent new questions, do not drop any, and do not merge or split them.
       Keep each question's wording essentially as written (you may tidy
       obvious typos or trailing punctuation, and trim to fit the length cap).
    2. For each question, choose the SINGLE best-fitting Verto answer type from
       the catalogue below, following the per-card rules.
    3. Supply that type's options. If the PDF lists answer options for the
       question, use them (mapped to the type's bounds). If the chosen type
       needs options and the PDF gives none, generate sensible, mutually-
       exclusive options that satisfy the rules.

    Per-card rules (every card must satisfy these):

    #{SurveyGenerator::CARD_RULES}

    Choosing the best-fitting type:
    - "Choose one" / single-pick → select_one_grid by default; fall back to
      multiple_choice when option labels are long (over ~14 chars) or there are
      more than 10 options.
    - "Choose all that apply" / multi-pick → select_many_grid by default; fall
      back to select_many for long labels or more than 10 options.
    - A 1-5 quality/satisfaction rating ("How would you rate…") → rating.
    - An emotion/agreement/"how often" scale → range (<= 5 points).
    - Likelihood-to-recommend or a 0-10 / reactive sentiment scale → nps
      (EXACTLY 5 points).
    - A single topic probed from three angles (or an explicit
      negative/neutral/positive set) → tap_card (EXACTLY 3 statements, in
      negative → neutral → positive order, each <= 30 chars).
    - A strict binary gate → yes_no (use sparingly).
    - An open, qualitative "tell us…" / "why…" question with no fixed answers →
      open_ended.
    - NEVER emit a welcome_card — the import contains only the user's questions.

    When in doubt between a grid and a list, prefer the grid. When in doubt
    between rating, range and nps, pick the one whose framing matches the
    question (stars → rating; emotion/agreement slider → range;
    likelihood/recommendation → nps).

    Output via the emit_survey tool. Infer a short `title` (and an optional
    `description`) from the PDF's subject; if nothing obvious, use a generic
    title like "Imported Verto".
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
  end

  # pdf_data: the uploaded PDF as a base64-encoded string.
  # Returns string-keyed { "title" => ..., "description" => ..., "cards" => [...] }.
  def call(pdf_data:, locale: SupportedLocales::DEFAULT)
    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      [ { type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } } ],
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "emit_survey" },
      messages: [
        {
          role: "user",
          content: [
            { type: "document", source: { type: "base64", media_type: "application/pdf", data: pdf_data } },
            { type: "text", text: "Extract every question from this PDF and map each to its best-fitting Verto answer type." }
          ]
        }
      ]
    )

    log_usage("PdfQuestionImporter", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    payload = deep_stringify(input_of(block))
    payload["cards"] = normalize_cards(payload["cards"])
    payload
  end

  private

  # Keep only well-formed cards of a generatable type, clean their options, and
  # enforce the structural caps the editor/player rely on. Anything malformed is
  # dropped rather than rendered broken.
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
      options = options.first(3) if type == "tap_card"
      out["options"] = options unless TYPES_WITHOUT_OPTIONS.include?(type) || options.empty?

      out["allow_other"] = true if card["allow_other"] == true
      out
    end
  end

  # tool_use?, input_of, deep_stringify come from AnthropicHelpers.
end
