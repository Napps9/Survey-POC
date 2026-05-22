require "anthropic"

class SurveyGenerator
  MODEL = "claude-sonnet-4-6"
  MAX_TOKENS = 4096

  CARD_TYPES = %w[
    welcome_card
    multiple_choice
    select_many
    select_one_grid
    select_many_grid
    tap_card
    range
    rating
    nps
    yes_no
    open_ended
  ].freeze

  # Card types the generator may emit — respects feature flags (e.g. nps).
  def self.generatable_types
    CARD_TYPES.select { |t| CardTypes.enabled?(t) }
  end

  TOOL = {
    name: "emit_survey",
    description: "Emit a structured survey that strictly follows the survey design rules.",
    input_schema: {
      type: "object",
      properties: {
        title:        { type: "string", description: "Short Verto title" },
        description:  { type: "string", description: "1-2 sentence intro shown to respondents" },
        theme:        { type: "string", description: "Echo the user's provided theme" },
        audience_age: { type: "string", description: "Echo the user's target audience age" },
        key_insight:  { type: "string", description: "Echo the user's key insight goal" },
        cards: {
          type: "array",
          minItems: 10,
          maxItems: 16,
          description: "Ordered list. Question count (excluding welcome_card) must be 10-15.",
          items: {
            type: "object",
            properties: {
              type: { type: "string", enum: CARD_TYPES },
              text: {
                type: "string",
                description: "Question or card text. Target 50-70 chars; 100 hard max. Any description SHARES this budget (text + description <= 100)."
              },
              description: {
                type: "string",
                description: "Optional sub-text under the question. SHARES the question's 100-char budget (text + description <= 100)."
              },
              options: {
                type: "array",
                items: { type: "string", description: "Each option <= 20 chars in select-one lists." },
                description: <<~DESC
                  Required for: multiple_choice, select_many, select_one_grid, select_many_grid,
                  tap_card, range, rating. Bounds (per the design rules):
                  - multiple_choice / select_many: 3 to 5 options, each <= 20 chars
                  - select_one_grid / select_many_grid: EVEN count, 4 to 10 including any "Other"
                  - tap_card: 3 to 5 cards
                  - range / rating: 3 to 5 points, never more than 5
                  - nps: 4 to 11 points (default 5-7), each label <= 20 chars
                DESC
              }
            },
            required: %w[type text]
          }
        }
      },
      required: %w[title description theme audience_age key_insight cards]
    }
  }.freeze

  # Per-card design rules that apply to a single question card. Shared by the
  # full-survey SYSTEM prompt and SingleQuestionGenerator so the two creation
  # paths can't drift apart.
  CARD_RULES = <<~RULES.freeze
    - List types (multiple_choice / select_many): 3 to 5 options, each <= 20 chars.
    - Grids (select_one_grid / select_many_grid): EVEN option count, 4 to 10
      total including any "Other".
    - tap_card: 3 to 5 cards - never fewer than 3, never more than 5.
    - range / rating: 3 to 5 points; never more than 5.
    - nps: a likelihood/sentiment scale with a reacting themed visual. 4 to 11
      points (default 5-7); each option label <= 20 chars. This is the only
      scale allowed more than 5 points.
    - Question text: 50-70 chars target, 100 hard max. Any description below the
      question SHARES that same 100-char budget (text + description <= 100).
    - "How often" questions: default to range with <= 5 options. If more are
      genuinely required, fall back rating -> multiple_choice -> select_one_grid;
      never exceed 5 options for a "How often" question.
  RULES

  SYSTEM = <<~PROMPT.freeze
    You are a Verto designer. Given a brief, produce a Verto experience that
    strictly follows the rules below. Deviate only when the brief explicitly
    requires it, and in that case keep the deviation minimal. Echo the user's
    theme, audience_age, and key_insight into the output unchanged.

    Do's and Don'ts (deviate only when the brief explicitly requires it, and
    keep any deviation minimal):

    1. Length — Target 10 to 15 questions; never exceed 15. Fewer questions is
       not automatically better. Welcome cards do not count toward the total.

    2. Question definition — A "question" is anything the user must read and
       respond to. A range counts as 1 question. A tap_card with 5 cards counts
       as 5 questions.

    3. Answer-type variety — Never place more than 2 of the same answer type in
       a row in the flow. Treat range, rating and nps as one "scale" family —
       avoid more than 2 of those sliders in a row.

    4. Welcome cards — At most ONE welcome_card, and only for cold/new audiences
       (briefly stating the Verto's purpose). Omit it for captive audiences or
       events where an introduction is unnecessary.

    5. Per-card rules — every question card must satisfy:

    #{CARD_RULES}

    Output via the emit_survey tool. Choose card types thoughtfully — the
    Verto answer type definitions below tell you when each is the right fit.

    DEFAULT FOR ANY "CHOOSE ONE" QUESTION: use select_one_grid.
    DEFAULT FOR ANY "CHOOSE MANY" QUESTION: use select_many_grid.
    Every single- or multi-pick question is now visual — the plain text
    button list has been retired. Default to the grid; only fall back to
    multiple_choice or select_many (which render as an image LIST — a
    small coloured tile on the left of each row instead of a button) when
    option labels are too long to fit a tile (over ~14 characters) or the
    question genuinely needs more than 10 options.

    - select_one_grid (Verto "Pick One — image grid"): DEFAULT for single-
      pick questions. 2×2 to 3×3 visual tiles, even option counts up to 10.
      Each tile can carry an image, icon, or coloured swatch — far more
      engaging than a plain list. Use this whenever options can be
      represented visually or fit short labels.
    - select_many_grid (Verto "Select Many — image grid"): DEFAULT for
      multi-pick questions. Same visual tile grid, multi-select. Even option
      counts up to 10. Use this whenever multiple answers can apply and
      options can be represented visually or fit short labels.
    - multiple_choice (Verto "Pick One — image list"): vertical list,
      single pick, with a small coloured tile on the left of each option.
      Use as the fallback when labels are too long for a grid tile
      (over ~14 chars) or the question needs more than 10 options. Up to
      ~5 options is best. Can include an "Other".
    - select_many (Verto "Select Many — image list"): same image-list
      layout, multi-pick. Use ONLY when select_many_grid won't fit (long
      labels or more than 10 options).
    - tap_card (Verto "Tap"): a sequence of cards, each card is its own
      mini-question with 2–3 quick choices. Best when you want lots of data
      points fast across related concepts (e.g. quick reactions to a series
      of statements or images). Aim for 3–5 cards; per Verto rules tap_card
      "options" should reflect ~3 cards' worth of distinct concepts.
    - range (Verto "Range"): playful 5-point sliding scale for emotion or
      agree/disagree. Five custom icons animate as the player drags. Use for
      mood, satisfaction, agreement — anything qualitative-scaled.
    - rating (Verto "Rating"): icon-based scale (stars by default, but icons
      can be customised). Use for "how good was X" questions. Can also stand
      in for range when iconography matters more than animation.
    - nps (Verto "NPS / Reactive scale"): a likelihood/sentiment slider where
      the answer control itself is a themed visual that reacts and fills as the
      respondent drags it (e.g. a thermometer, cup, gauge, or expressive
      character chosen to fit the brief's theme, audience and tone). Use for
      likelihood-to-recommend, satisfaction, mood or temperature checks. 4–11
      points (default 5–7); labels can be numbers, words or emotions. Prefer
      this over rating when an engaging, on-theme reaction adds value.
    - yes_no: simple gating only. Use sparingly — a select_one_grid with
      two visual options is often richer.
    - open_ended (Verto "Freeform"): text input, can be voice-recorded too.
      Use sparingly to capture authentic qualitative voice.
    - select_one_grid as "Prioritise" surrogate: Verto's Prioritise lets
      players drag-rank ~5 items. We don't have a dedicated type — use
      select_one_grid with 4–6 options and phrase the question as ranking
      ("In what order would you…"). Prefer this over a flat select for
      explicit priority questions.
    - welcome_card: not a question; flow control per the rules.

    When relevant historical Playverto questions are provided in the brief,
    use them to inform wording style and answer-type selection. Do NOT copy
    them verbatim — adapt to the brief's audience and insight. The design
    rules above always override any pattern from the historical examples.

    Self-check before emitting — re-read your draft and fix any rule violation
    (unless the brief explicitly requires the exception):
    [ ] 10 to 15 questions (welcome cards excluded); at most 1 welcome card
    [ ] No more than 2 of the same answer type in a row
    [ ] Lists 3-5 options (each <= 20 chars); grids EVEN and 4-10; tap_card 3-5;
        range/rating <= 5; nps 4-11
    [ ] Every question's text plus its description <= 100 chars
    [ ] "How often" -> range with <= 5 options
    [ ] theme, audience_age and key_insight echoed back unchanged
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
  end

  def call(theme:, audience_age:, key_insight:, notes: nil, locale: SupportedLocales::DEFAULT)
    brief = [ theme, audience_age, key_insight, notes ].compact.join(" ")
    examples = QuestionCorpus.search(brief, limit: 8, min_overlap: 2)
    Rails.logger.info("[corpus] matched #{examples.size} of #{QuestionCorpus.all.size}: " +
                      examples.first(5).map { |e| e[:question].truncate(60) }.join(" | "))

    user_message = +<<~MSG
      Theme: #{theme}
      Target audience age: #{audience_age}
      Key insight hoping to be achieved: #{key_insight}
      Additional notes: #{notes.to_s.strip.empty? ? '(none)' : notes}
    MSG

    if examples.any?
      user_message << "\nVocabulary reference (NOT a checklist, NOT to be copied): " \
                      "a few historical Playverto questions touching similar topics, " \
                      "useful only for tone and which answer types tend to suit which " \
                      "concepts. Ignore any that don't fit this brief.\n"
      examples.each do |e|
        type_hint = e[:primary_type].presence || "n/a"
        user_message << %(- "#{e[:question]}" [#{type_hint}]\n)
      end
    end

    user_message << <<~REMINDER

      Now design the Verto for THIS brief. Strictly follow the design rules
      from the system prompt:
      - 10 to 15 questions total (welcome_card doesn't count)
      - no more than 2 of the same answer type in a row
      - DEFAULT every single-pick question to select_one_grid and every
        multi-pick to select_many_grid; only fall back to multiple_choice /
        select_many when option labels are over ~14 chars or the question
        needs more than 10 options
      - tap_card 3-5 options · grids even count, ≤10
      - question text 50-70 chars target, never exceed 100
      - option text ≤ 14 chars when using a grid; ≤ 20 chars in a text list
      - include a welcome_card only if the audience is cold/new
      Echo theme, audience_age, key_insight unchanged. Output via the
      emit_survey tool.
    REMINDER

    user_message << language_instruction(locale)

    tool = TOOL.deep_dup
    tool[:input_schema][:properties][:cards][:items][:properties][:type][:enum] = self.class.generatable_types

    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: [ tool ],
      tool_choice: { type: "tool", name: "emit_survey" },
      messages: [ { role: "user", content: user_message } ]
    )

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    deep_stringify(input_of(block))
  end

  private

  # When the primary language isn't English, instruct the model to write the
  # whole Verto in that language (respondent-facing text + every option label).
  def language_instruction(locale)
    return "" if locale.to_s == SupportedLocales::DEFAULT

    lang = SupportedLocales.find(locale)
    name = lang ? "#{lang.english_name} (#{lang.native_name})" : locale.to_s
    <<~LANG

      LANGUAGE: Write the ENTIRE Verto — title, description, every question's
      text and description, and ALL answer option labels — in #{name}. Do not
      use English for any respondent-facing text. Keep the same design rules and
      length limits.
    LANG
  end

  def tool_use?(block)
    type = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
    type.to_s == "tool_use"
  end

  def input_of(block)
    raw = block.respond_to?(:input) ? block.input : (block[:input] || block["input"])
    raw.respond_to?(:to_h) ? raw.to_h : raw
  end

  def deep_stringify(obj)
    case obj
    when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
    when Array then obj.map { |v| deep_stringify(v) }
    else obj
    end
  end
end
