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
              type: { type: "string", enum: QuestionTypeClassifier::CLASSIFIABLE_TYPES, description: "The best-fitting answer type for this question." },
              original_text: { type: "string", description: "The question text EXACTLY as written in the PDF, unmodified." },
              compliant: { type: "boolean", description: "true when original_text already satisfies every per-card rule verbatim (length caps, single idea, neutral wording). false when it needed rewriting." },
              issue: { type: "string", description: "Only when compliant is false: one short sentence naming the rule it breaks (e.g. 'Over the 100-character cap' or 'Asks two things at once')." },
              text: { type: "string", description: "The rule-compliant question text. When compliant is true this is identical to original_text. When false, it is the optimised rewrite: same intent, shorter and sharper. Target 50-70 chars; 100 hard max (text + any description <= 100). For a scenario, this is the short question asked on the final page, not the narrative." },
              description: { type: "string", description: "Optional sub-text under the question. Shares the question's 100-char budget." },
              pages: {
                type: "array",
                items: { type: "string", description: "One narrative page's text." },
                description: "SCENARIO ONLY. The PDF's narrative situation split into 1-5 pages, each a short paragraph (<= 400 chars), in reading order. Preserve the source wording — do not invent story content."
              },
              options: {
                type: "array",
                items: { type: "string", description: "Each option label within its type's character budget (see the design rules)." },
                description: <<~DESC
                  Required for: multiple_choice, select_many, select_one_grid,
                  select_many_grid, prioritise, tap_card, range, rating, nps, scenario. Use the
                  options written in the PDF when present; otherwise generate sensible,
                  mutually-exclusive options that satisfy the bounds:
                  - multiple_choice / select_many: ODD count — 3 or 5 options, each <= 40 chars
                  - select_one_grid / select_many_grid: EVEN count, 4 to 10 including any
                    "Other", each label <= 20 chars
                  - prioritise: 4 or 5 options (4 ideal), each <= 40 chars
                  - tap_card: 5 to 8 statements covering negative, neutral and positive
                    sentiments in that order, each <= 40 chars
                  - range: EXACTLY 5 points — never 3, never 4 — with a genuinely
                    neutral MIDDLE label (the 3rd)
                  - rating: 3 to 5 points (5 ideal), ONE label per point, never more than 5
                  - nps: EXACTLY 11 numeric labels, "0" through "10" — no word labels
                  - scenario: 2 or 3 options, each <= 30 chars
                DESC
              },
              allow_other: { type: "boolean", description: "Set true only if the question explicitly offers a free-text 'Other'." }
            },
            required: %w[type text original_text compliant]
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
       Record each question's wording EXACTLY as written in `original_text`.
    2. Judge whether the original wording already satisfies every per-card
       rule below (length caps, one idea per question, neutral phrasing).
       - If it does: set `compliant: true` and `text` = `original_text`.
       - If it does not: set `compliant: false`, name the broken rule in one
         short sentence in `issue`, and write the optimised rewrite in `text`
         — same intent, shorter and sharper, fully rule-compliant. The user
         chooses between the two; never silently rewrite a compliant question.
    3. For each question, choose the SINGLE best-fitting Verto answer type from
       the catalogue below, following the per-card rules.
    4. Supply that type's options. If the PDF lists answer options for the
       question, use them (mapped to the type's bounds). If the chosen type
       needs options and the PDF gives none, generate sensible, mutually-
       exclusive options that satisfy the rules.

    Per-card rules (every card must satisfy these):

    #{SurveyGenerator::CARD_RULES}

    Choosing the best-fitting type:
    - "Choose one" / single-pick → select_one_grid by default; fall back to
      multiple_choice when option labels are long (over ~14 chars).
    - "Choose all that apply" / multi-pick → select_many_grid by default; fall
      back to select_many for long labels.
    - An explicit ranking question ("In what order…", "Rank these…") →
      prioritise (4 or 5 options, 4 ideal).
    - A 1-5 quality/satisfaction rating ("How would you rate…") → rating
      (one label per point).
    - An emotion/agreement/"how often" scale → range (odd count, 3 or 5
      points, with a genuine neutral middle).
    - Likelihood-to-recommend or a 0-10 sentiment/temperature scale → nps
      (EXACTLY 11 numeric labels, "0" through "10").
    - A single topic probed from several angles (or an explicit
      negative/neutral/positive statement set) → tap_card (5 to 8 statements,
      in negative → neutral → positive order, each <= 40 chars).
    - A strict binary gate → yes_no (use sparingly).
    - An open, qualitative "tell us…" / "why…" question with no fixed answers →
      open_ended.
    - A question whose full wording can't be kept within its type's length
      cap without cutting real content, or a multi-sentence narrative
      situation ("Imagine you…", "You are faced with…") that puts the
      reader in a scene before offering 2-3 options → scenario. Don't
      silently shorten a long, information-carrying question into a
      truncated blurb — split it into `pages` (1-5 short paragraphs,
      reading order, source wording preserved) and put the closing options
      in `options` (2-3, each <= 30 chars). Both `text` AND `original_text`
      for a scenario are the short closing question only (e.g. "Which
      would you choose?") — never the full narrative, which belongs
      entirely in `pages`. Only choose scenario when there's genuinely a
      story/situation to read first — a single plain sentence with options
      is multiple_choice, not scenario.
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
    @client = build_anthropic_client(api_key)
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
    payload["cards"] = QuestionTypeClassifier.new.normalize_cards(payload["cards"])
    payload
  end

  # tool_use?, input_of, deep_stringify come from AnthropicHelpers.
end
