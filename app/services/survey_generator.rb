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
    yes_no
    open_ended
  ].freeze

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
                description: "Question or card text. Target 50-70 chars; never exceed 100. Description below counts toward this budget."
              },
              description: {
                type: "string",
                description: "Optional sub-text shown under the question. Counts toward the 100-char budget."
              },
              options: {
                type: "array",
                items: { type: "string", description: "Each option <= 20 chars in select-one lists." },
                description: <<~DESC
                  Required for: multiple_choice, select_many, select_one_grid, select_many_grid,
                  tap_card, range, rating. Bounds:
                  - tap_card: 3 to 5
                  - multiple_choice / select_many: 3 to 5
                  - select_one_grid / select_many_grid: even count, max 10 including any "Other"
                  - range / rating: 3 to 5 points
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

  SYSTEM = <<~PROMPT.freeze
    You are a Verto designer. Given a brief, produce a Verto experience that
    strictly follows the rules below. Deviate only when the brief explicitly
    requires it, and in that case keep the deviation minimal. Echo the user's
    theme, audience_age, and key_insight into the output unchanged.

    Do's and Don'ts:

    1. Length — Target 10 to 15 questions. Fewer questions is not necessarily
       easier or faster. Do NOT exceed 15 questions. Welcome cards do not
       count toward the question total.

    2. Question definition — A "question" is anything the user must read and
       respond to with a choice. A range counts as 1 question. A tap_card with 5
       cards counts as 5 questions.
       - Do NOT include more than 2 of the same answer type in a row in the flow
         (rare exceptions allowed).
       - tap_card must have 3 to 5 cards. Never fewer than 3, never more than 5.

    3. Welcome cards — Include ONE welcome_card only for cold/new audiences,
       briefly stating the Verto's purpose. Do NOT include a welcome_card for
       captive audiences or events where introduction is unnecessary. Maximum 1
       welcome card.

    4. Answer diversity — No flow may contain more than two of the same answer
       type consecutively. Exceptions allowed only when the brief demands it.

    5. Number of answer choices — Provide 3 to 5 choices per question. Do NOT
       exceed 5 for range/rating except in specific cases.

    6. Grid format (select_one_grid / select_many_grid) — Use an EVEN number of
       answer choices for visual balance. Total options including any "Other"
       must not exceed 10.

    7. Question length — Keep question text between 50 and 70 characters. Up to
       100 characters is allowed only when the answer type genuinely requires
       it. Never exceed 100 without strong reason.

    8. Descriptions below questions — A description below a question counts
       toward the same character budget. Do NOT exceed limits.

    9. Answer length — Keep each answer choice up to 20 characters in a
       select-one list. For grids, weigh option count against legibility.

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
    - nps (use type "rating" with appropriate options): Verto's NPS is a
      0–10 drag scale, also customisable to 4- or 5-point. Labels can be
      numbers, agreement, or emotion. Pick rating with a wider option count
      when you want NPS-style.
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
    them verbatim — adapt to the brief's audience and insight. The 9 design
    rules above always override any pattern from the historical examples.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
  end

  def call(theme:, audience_age:, key_insight:, notes: nil)
    brief = [theme, audience_age, key_insight, notes].compact.join(" ")
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

    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: [TOOL],
      tool_choice: { type: "tool", name: "emit_survey" },
      messages: [{ role: "user", content: user_message }]
    )

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    deep_stringify(input_of(block))
  end

  private

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
