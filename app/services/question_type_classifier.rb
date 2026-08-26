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

  # Types the classifier may assign — SurveyGenerator::CARD_TYPES plus
  # scenario. Scenario is deliberately import/classification-only: it's never
  # added to CARD_TYPES itself, so the freeform "generate a Verto from a
  # topic" flow (SurveyGenerator) can never invent one, while PDF/paste
  # imports and Common Question classification (both backed by this class)
  # can still recognize and produce one from a creator's own narrative text.
  CLASSIFIABLE_TYPES = (SurveyGenerator::CARD_TYPES + %w[scenario]).freeze

  # Belt-and-braces bound for a classified scenario's answer options —
  # mirrors SurveyGenerator::TAP_CARD_MAX_STATEMENTS for tap_card.
  SCENARIO_MAX_OPTIONS = 3

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
              type: { type: "string", enum: CLASSIFIABLE_TYPES, description: "Best-fitting answer type." },
              description: { type: "string", description: "Optional sub-text. Shares the 100-char budget with text." },
              pages: {
                type: "array",
                items: { type: "string", description: "One narrative page's text." },
                description: "SCENARIO ONLY. The input's narrative situation split into 1-5 pages, each a short paragraph (<= 400 chars), in reading order. Preserve the source wording — do not invent story content."
              },
              options: {
                type: "array",
                items: { type: "string", description: "Each option label within its type's character budget (see the design rules)." },
                description: <<~DESC
                  Required for: multiple_choice, select_many, select_one_grid,
                  select_many_grid, prioritise, tap_card, range, rating, nps, scenario.
                  Generate sensible, mutually-exclusive options that satisfy the bounds:
                  - multiple_choice / select_many: ODD count — 3 or 5 options, each <= 40 chars
                  - select_one_grid / select_many_grid: EVEN count, 4 to 10 including any
                    "Other", each label <= 20 chars
                  - prioritise: 4 or 5 options (4 ideal), each <= 40 chars
                  - tap_card: 5 to 8 statements covering negative, neutral and positive
                    sentiments in that order, each <= 40 chars
                  - range: EXACTLY 5 points — never 3, never 4 — with a genuinely
                    neutral MIDDLE label (the 3rd), each label <= 17 chars
                  - rating: 3 to 5 points (5 ideal), ONE label per point, never more than 5
                  - nps: EXACTLY 11 numeric labels, "0" through "10" — no word labels
                  - scenario: 2 or 3 options, each <= 30 chars
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
    - A question whose full wording can't be kept within its type's length
      cap without cutting real content, or a multi-sentence narrative
      situation ("Imagine you...", "You are faced with...") that puts the
      reader in a scene before offering 2-3 options -> scenario. Don't
      silently shorten a long, information-carrying question into a
      truncated blurb — split it into `pages` (1-5 short paragraphs,
      reading order, source wording preserved) and put the closing options
      in `options` (2-3, each <= 30 chars). Only choose scenario when the
      source text is genuinely a short story or situation — a single plain
      sentence with options is multiple_choice, not scenario, even if
      `pages` could technically hold it as one page.
    - NEVER emit a welcome_card — these are user-authored questions only.

    When in doubt between a grid and a list, prefer the grid. When in doubt
    between rating, range and nps, pick the one whose framing matches the
    question (stars -> rating; emotion/agreement slider -> range;
    likelihood/recommendation -> nps).

    CRITICAL: Echo each input question's `text` back exactly as supplied. Do
    not reword, translate, or punctuate-tidy. Preserve input order. For a
    scenario, `text` stays the short question asked on the final page (e.g.
    "Which would you choose?") — the narrative itself lives in `pages`.

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
  # cards of a generatable type (plus scenario, which is classification-only —
  # see CLASSIFIABLE_TYPES), clean options, enforce structural caps.
  # Public so other callers (PdfQuestionImporter) can reuse it.
  def normalize_cards(cards)
    allowed = SurveyGenerator.generatable_types | %w[scenario]
    Array(cards).filter_map do |card|
      next unless card.is_a?(Hash)
      type = card["type"].to_s
      text = card["text"].to_s.strip
      next if !allowed.include?(type) || text.empty?

      out = { "type" => type, "text" => text }
      out["description"] = card["description"].to_s.strip if card["description"].to_s.strip.present?
      out["pages"] = normalize_scenario_pages(card["pages"]) if type == "scenario"

      # Review-only fields (PdfQuestionImporter / ManualQuestionImporter) —
      # SurveysController reads `compliant` to decide whether to show the
      # verbatim-vs-optimised review screen, and `original_text`/`issue` to
      # render it. Carried through only when the caller's raw card actually
      # has them (QuestionTypeClassifier's own classify_questions tool never
      # emits these, so Common Question classification is unaffected).
      out["original_text"] = card["original_text"].to_s.strip if card["original_text"].to_s.strip.present?
      out["compliant"] = card["compliant"] if [ true, false ].include?(card["compliant"])
      out["issue"] = card["issue"].to_s.strip if card["issue"].to_s.strip.present?
      # "Keep my wording exactly as uploaded" restored only the question TEXT,
      # so a Verto whose every question was kept as written could still have the
      # model's wording — and the model's spelling — throughout its OPTIONS and
      # descriptions, with the review screen's diff showing none of it. These
      # are emitted only when the model actually changed something, so a
      # compliant card costs nothing to carry.
      originals = Array(card["original_options"]).map { |o| o.to_s.strip }.reject(&:empty?)
      out["original_options"] = originals if originals.any?
      if card["original_description"].to_s.strip.present?
        out["original_description"] = card["original_description"].to_s.strip
      end

      options = Array(card["options"]).map { |o| o.to_s.strip }.reject(&:empty?)
      options = options.first(SurveyGenerator::TAP_CARD_MAX_STATEMENTS) if type == "tap_card"
      options = options.first(SCENARIO_MAX_OPTIONS) if type == "scenario"
      out["options"] = options unless TYPES_WITHOUT_OPTIONS.include?(type) || options.empty?

      out["allow_other"] = true if card["allow_other"] == true
      out
    end
  end

  private

  # Bounds + assigns stable ids to a classified scenario's narrative pages,
  # mirroring Survey#sanitize_cards_images!'s scenario branch so an imported
  # card already satisfies the same caps the editor enforces on save.
  def normalize_scenario_pages(raw_pages)
    Array(raw_pages).first(Survey::MAX_SCENARIO_PAGES).filter_map do |p|
      text = p.to_s.strip.first(Survey::MAX_SCENARIO_PAGE_LENGTH)
      next if text.blank?
      { "id" => "pg_#{SecureRandom.hex(4)}", "text" => text }
    end
  end

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
