require "anthropic"

class SurveyGenerator
  MODEL = "claude-sonnet-4-6"
  MAX_TOKENS = 4096

  CARD_TYPES = %w[
    welcome_card
    static_page
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
        title:        { type: "string", description: "Short survey title" },
        description:  { type: "string", description: "1-2 sentence intro shown to respondents" },
        theme:        { type: "string", description: "Echo the user's provided theme" },
        audience_age: { type: "string", description: "Echo the user's target audience age" },
        key_insight:  { type: "string", description: "Echo the user's key insight goal" },
        cards: {
          type: "array",
          minItems: 10,
          maxItems: 17,
          description: "Ordered list. Question count (excluding welcome_card and static_page) must be 10-15.",
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
    You are a survey designer. Given a brief, produce a survey that strictly
    follows the rules below. Deviate only when the brief explicitly requires it,
    and in that case keep the deviation minimal. Echo the user's theme,
    audience_age, and key_insight into the output unchanged.

    Do's and Don'ts:

    1. Length — Target 10 to 15 questions. Fewer questions is not necessarily
       easier or faster. Do NOT exceed 15 questions. Welcome cards and static
       pages do not count toward the question total.

    2. Question definition — A "question" is anything the user must read and
       respond to with a choice. A range counts as 1 question. A tap_card with 5
       cards counts as 5 questions.
       - Do NOT include more than 2 of the same answer type in a row in the flow
         (rare exceptions allowed).
       - tap_card must have 3 to 5 cards. Never fewer than 3, never more than 5.

    3. Static page — If the survey has 15 questions, include ONE midway
       static_page to break flow and add light humor. Do NOT use narrative cards
       (they bloat the survey).

    4. Welcome cards — Include ONE welcome_card only for cold/new audiences,
       briefly stating the survey purpose. Do NOT include a welcome_card for
       captive audiences or events where introduction is unnecessary. Maximum 1
       welcome card.

    5. Answer diversity — No flow may contain more than two of the same answer
       type consecutively. Exceptions allowed only when the brief demands it.

    6. Number of answer choices — Provide 3 to 5 choices per question. Do NOT
       exceed 5 for range/rating except in specific cases.

    7. Grid format (select_one_grid / select_many_grid) — Use an EVEN number of
       answer choices for visual balance. Total options including any "Other"
       must not exceed 10.

    8. Question length — Keep question text between 50 and 70 characters. Up to
       100 characters is allowed only when the answer type genuinely requires
       it. Never exceed 100 without strong reason.

    9. Descriptions below questions — A description below a question counts
       toward the same character budget. Do NOT exceed limits.

    10. Answer length — Keep each answer choice up to 20 characters in a
        select-one list. For grids, weigh option count against legibility.

    Output via the emit_survey tool. Choose card types thoughtfully — the
    Verto answer type definitions below tell you when each is the right fit:

    - multiple_choice (Verto "Select One"): the most popular type. List or
      grid of options, player picks one. Use list for any number of options;
      use a grid (even count) when the option count is even and looks tidy
      on mobile. Up to ~5 options. Can include an "Other" entry. Use this
      whenever the answer space is well-defined and discrete.
    - select_many (Verto "Select Many"): same UI as Select One but allows
      multiple choices. Use when more than one answer is genuinely possible.
    - select_one_grid / select_many_grid (Verto "Matrix"): up to ~8 sub-
      questions sharing the SAME answer set, with consistent column labels.
      Great for rating multiple sub-topics on the same scale efficiently.
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
    - yes_no: simple gating only. Use sparingly — Select One with two
      options is often richer.
    - open_ended (Verto "Freeform"): text input, can be voice-recorded too.
      Use sparingly to capture authentic qualitative voice.
    - select_one_grid as "Prioritise" surrogate: Verto's Prioritise lets
      players drag-rank ~5 items. We don't have a dedicated type — use
      select_one_grid with 4–6 options and phrase the question as ranking
      ("In what order would you…"). Prefer this over a flat select for
      explicit priority questions.
    - welcome_card / static_page: not questions; flow control per the rules.

    When relevant historical Playverto questions are provided in the brief,
    use them to inform wording style and answer-type selection. Do NOT copy
    them verbatim — adapt to the brief's audience and insight. The 10 design
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

      Now design the survey for THIS brief. Strictly follow the design rules
      from the system prompt:
      - 10 to 15 questions total (welcome_card / static_page don't count)
      - no more than 2 of the same answer type in a row
      - tap_card 3-5 options · multi-choice 3-5 options · grids even count, ≤10
      - question text 50-70 chars target, never exceed 100
      - option text ≤ 20 chars in select-one lists
      - include a welcome_card only if the audience is cold/new
      - include one static_page only if the survey hits 15 questions
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
