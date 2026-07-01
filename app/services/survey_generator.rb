require "anthropic"

class SurveyGenerator
  include AnthropicHelpers

  MODEL = ClaudeModels::DEFAULT
  MAX_TOKENS = 4096

  CARD_TYPES = %w[
    welcome_card
    multiple_choice
    select_many
    select_one_grid
    select_many_grid
    prioritise
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
                  prioritise, tap_card, range, rating. Bounds (per the design rules):
                  - multiple_choice / select_many: 3 to 5 options, each <= 20 chars
                  - select_one_grid / select_many_grid: EVEN count, 4 to 10 including any "Other"
                  - prioritise: 3 to 6 options (about 5 ideal), each <= 24 chars
                  - tap_card: EXACTLY 3 cards (negative / neutral / positive sentiments)
                  - range / rating: 3 to 5 points, never more than 5
                  - nps: EXACTLY 5 points, each label <= 20 chars
                DESC
              },
              id: {
                type: "integer",
                description: "Echo back the id of a Common Question card supplied in the brief. Set only on those cards; leave unset on any new card you write."
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
    - prioritise: 3 to 6 options (about 5 ideal), each <= 24 chars. Use when
      the ORDER of preference matters (rank these highest to lowest).
    - tap_card: EXACTLY 3 cards. The three statements MUST represent a
      NEGATIVE, a NEUTRAL and a POSITIVE sentiment on the question's
      topic, in that order (index 0 = negative, 1 = neutral, 2 = positive).
      Each statement is its own swipe card; the respondent swipes yes/no
      on each, and the combination reveals their sentiment.
      Keep each statement <= 30 characters.
    - range / rating: 3 to 5 points; never more than 5.
    - nps: a likelihood/sentiment scale with a reacting themed visual.
      EXACTLY 5 points; each option label <= 20 chars.
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
       respond to. A range counts as 1 question. A tap_card with its 3
       statements (negative/neutral/positive) counts as 3 questions.

    3. Answer-type variety — Never place more than 2 of the same answer type in
       a row in the flow. Treat range, rating and nps as one "scale" family —
       avoid more than 2 of those sliders in a row.

    4. Welcome cards — ALWAYS begin with exactly ONE welcome_card that briefly
       sets the scene (states the Verto's purpose). Keep it short and warm.

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
    - tap_card (Verto "Tap"): a swipe stack of EXACTLY 3 statements about
      the question's topic. The three statements MUST express a NEGATIVE,
      NEUTRAL and POSITIVE sentiment on the topic, in that order. The
      respondent swipes yes/no on each; the combination reveals their
      stance. Each statement <= 30 characters. Best when you want quick
      gut reactions to a single subject from three angles.
    - range (Verto "Range"): playful 3-5 point sliding scale for emotion or
      agree/disagree, where the left panel plays a reactive Lottie animation
      matched to the slider position — an engaging on-theme reaction. Use for
      mood, satisfaction, agreement — anything qualitative-scaled; prefer this
      when an engaging visual lifts response quality.
    - rating (Verto "Rating"): icon-based scale (stars by default, but icons
      can be customised). Use for "how good was X" questions. Can also stand
      in for range when familiar iconography matters more than the animation.
    - nps (Verto "NPS"): a likelihood/sentiment 5-point vertical slider (a
      plain scale, no reaction animation). Use for likelihood-to-recommend,
      satisfaction, mood or temperature checks. EXACTLY 5 points; labels can
      be numbers, words or emotions. Prefer range when an engaging on-theme
      reaction adds value.
    - yes_no: simple gating only. Use sparingly — a select_one_grid with
      two visual options is often richer.
    - open_ended (Verto "Freeform"): text input, can be voice-recorded too.
      Use sparingly to capture authentic qualitative voice.
    - prioritise (Verto "Prioritise"): a list respondents drag into an order
      of priority — highest to lowest (or most-to-least agree/liked). Use for
      explicit ranking questions ("In what order…", "Rank these…") where the
      ORDER of preference is the insight, not just which options are picked.
      3 to 6 options, about 5 ideal.
    - welcome_card: not a question; flow control per the rules.

    When relevant historical Playverto questions are provided in the brief,
    use them to inform wording style and answer-type selection. Do NOT copy
    them verbatim — adapt to the brief's audience and insight. The design
    rules above always override any pattern from the historical examples.

    Self-check before emitting — re-read your draft and fix any rule violation
    (unless the brief explicitly requires the exception):
    [ ] 10 to 15 questions (welcome cards excluded); starts with exactly 1 welcome card
    [ ] No more than 2 of the same answer type in a row
    [ ] Lists 3-5 options (each <= 20 chars); grids EVEN and 4-10; tap_card EXACTLY 3 (neg/neutral/pos);
        range/rating <= 5; nps EXACTLY 5
    [ ] Every question's text plus its description <= 100 chars
    [ ] "How often" -> range with <= 5 options
    [ ] theme, audience_age and key_insight echoed back unchanged
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  def call(theme:, audience_age:, key_insight:, notes: nil, locale: SupportedLocales::DEFAULT, common_cards: [], quiz: false)
    brief = [ theme, audience_age, key_insight, notes ].compact.join(" ")
    examples = QuestionCorpus.search(brief, limit: 8, min_overlap: 2)
    Rails.logger.info("[corpus] matched #{examples.size} of #{QuestionCorpus.all.size}: " +
                      examples.first(5).map { |e| e[:question].truncate(60) }.join(" | "))

    common_cards = Array(common_cards).select { |c| c.is_a?(Hash) && c["common_question_id"] }

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
      - tap_card EXACTLY 3 (neg/neutral/pos) options · grids even count, ≤10
      - question text 50-70 chars target, never exceed 100
      - option text ≤ 14 chars when using a grid; ≤ 20 chars in a text list
      - ALWAYS start with exactly one welcome_card that sets the scene
      Echo theme, audience_age, key_insight unchanged. Output via the
      emit_survey tool.
    REMINDER

    user_message << language_instruction(locale)
    user_message << common_cards_instruction(common_cards)
    user_message << quiz_instruction if quiz

    tool = TOOL.deep_dup
    tool[:input_schema][:properties][:cards][:items][:properties][:type][:enum] = self.class.generatable_types
    inject_quiz_schema!(tool) if quiz
    # Cache the static prefix (tools render before system, so a marker on the
    # last tool caches the tool schema + SYSTEM together). The enum is
    # deterministic, so the cached prefix bytes are stable across calls.
    tool[:cache_control] = { type: "ephemeral" }

    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: [ tool ],
      tool_choice: { type: "tool", name: "emit_survey" },
      messages: [ { role: "user", content: user_message } ]
    )
    log_usage("SurveyGenerator", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    payload = deep_stringify(input_of(block))
    enforce_tap_card_three_statements!(payload)
    ensure_welcome_card!(payload)
    reconcile_common_cards!(payload, common_cards)
    normalize_quiz_correct!(payload) if quiz
    payload
  end

  # Add the quiz fields to the emit_survey schema so the model can mark correct
  # answers + explanations. Only the standard quiz types are gradable by the
  # generator; scales/tap_card stay as ordinary measurement questions (a creator
  # can still grade those by hand in the editor).
  def inject_quiz_schema!(tool)
    props = tool[:input_schema][:properties][:cards][:items][:properties]
    props[:correct] = {
      type: "array",
      items: { type: "string" },
      description: "QUIZ ONLY. The correct option label(s): one label for " \
                   "multiple_choice / yes_no / select_one_grid; all correct labels for " \
                   "select_many / select_many_grid; one or more acceptable answers for " \
                   "open_ended. OMIT for ungraded questions and for range, nps, rating, " \
                   "tap_card and welcome_card."
    }
    props[:explanation] = {
      type: "string",
      description: "QUIZ ONLY. One short sentence explaining the correct answer, shown " \
                   "to the player after they answer. Set only on graded cards."
    }
  end

  # Trust nothing: coerce the model's `correct` into the stored shape and drop
  # it unless it genuinely matches the card's options (so a stray or malformed
  # value just leaves the question ungraded rather than always-wrong).
  def normalize_quiz_correct!(payload)
    Array(payload["cards"]).each do |card|
      raw  = Array(card["correct"]).map { |x| x.to_s.strip }.reject(&:empty?)
      opts = Array(card["options"])
      norm =
        case card["type"].to_s
        when "multiple_choice", "select_one_grid"
          raw.find { |r| opts.include?(r) }
        when "yes_no"
          raw.filter_map { |r| r.casecmp?("yes") ? "Yes" : (r.casecmp?("no") ? "No" : nil) }.first
        when "select_many", "select_many_grid"
          (opts & raw).presence
        when "open_ended"
          raw.presence
        end

      if norm.nil? || (norm.respond_to?(:empty?) && norm.empty?)
        card.delete("correct")
        card.delete("explanation")
      else
        card["correct"] = norm
        card.delete("explanation") if card["explanation"].to_s.strip.empty?
      end
    end
    payload
  end

  # Every Verto opens with a welcome card. The model is asked to include one,
  # but it sometimes omits it for captive audiences — so guarantee it here by
  # prepending a simple one built from the brief when none is present.
  def ensure_welcome_card!(payload)
    cards = Array(payload["cards"])
    return payload if cards.any? { |c| c["type"].to_s == "welcome_card" }

    welcome = {
      "type"  => "welcome_card",
      "title" => payload["title"].to_s.strip.presence || payload["theme"].to_s.strip.presence || "Welcome",
      "text"  => payload["description"].to_s.strip.presence || payload["theme"].to_s.strip.presence
    }.compact
    payload["cards"] = [ welcome ] + cards
    payload
  end

  # Belt-and-braces post-generation guard for the "tap_card MUST be exactly
  # 3 statements (neg/neutral/pos)" rule. The system prompt asks Claude for
  # this directly, but Claude occasionally deviates with 4-5 statements;
  # trimming to the first 3 keeps the rule strict without losing the
  # ordering Claude already produced (the prompt asks for neg → neutral →
  # positive in index order).
  def enforce_tap_card_three_statements!(payload)
    Array(payload["cards"]).each do |card|
      next unless card["type"].to_s == "tap_card"
      opts = Array(card["options"])
      card["options"] = opts.first(3) if opts.size > 3
    end
  end

  # Belt-and-braces verbatim guarantee for Common Question cards. The model
  # is told to echo each common card's id back in `id` and leave its text /
  # type / options untouched, but we don't trust it. Walk the emitted cards:
  # for any with a known id, overwrite its mutable fields with the master
  # snapshot so the wording is byte-identical to what the user authored.
  # Append any expected ids the model omitted, and strip stray `id` fields
  # from non-common cards.
  def reconcile_common_cards!(payload, common_cards)
    return if common_cards.empty?

    expected_by_id = common_cards.index_by { |c| c["common_question_id"] }
    seen_ids       = []

    Array(payload["cards"]).each do |card|
      id = card["id"]
      master = expected_by_id[id]
      if master
        card["text"]                    = master["text"]
        card["type"]                    = master["type"]
        card["options"]                 = master["options"]                 if master["options"]
        card["description"]             = master["description"]             if master["description"]
        card["allow_other"]             = master["allow_other"]             if master.key?("allow_other")
        card["common_question_id"]      = master["common_question_id"]
        card["common_question_set_id"]  = master["common_question_set_id"]
        seen_ids << id
      end
      card.delete("id")
    end

    missing = expected_by_id.keys - seen_ids
    missing.each do |id|
      payload["cards"] << expected_by_id[id].dup.tap { |c| c.delete("id") }
    end
  end

  private

  # System-prompt-equivalent instructions for weaving Common Question cards
  # into the deck. Lives in the user message rather than the cached SYSTEM
  # so prompt caching survives selection changes.
  def common_cards_instruction(common_cards)
    return "" if common_cards.empty?

    cards_for_prompt = common_cards.map do |c|
      {
        id:      c["common_question_id"],
        type:    c["type"],
        text:    c["text"],
        options: c["options"]
      }.compact
    end

    <<~MSG

      COMMON QUESTIONS — VERBATIM INSERTION (#{common_cards.size} card#{'s' if common_cards.size != 1})
      The user has attached the reusable cards below. You MUST include EVERY one
      in your emitted `cards` array. For each, echo back the supplied `id` so we
      can identify it. Do NOT change `text`, `type`, `options` or `description`
      on any of these cards — they are authored content and must read verbatim.

      Place each one at the most contextually appropriate position in the deck —
      can be at the start, middle, or end, surrounded by your generated cards
      where the topic fits naturally. The Rules of the Game still apply to the
      ENTIRE integrated deck (10-15 questions total, no more than 2 of the same
      answer type in a row including common cards, etc.) — choose and order
      your own generated cards so the integrated flow satisfies them.

      COMMON CARDS:
      #{JSON.pretty_generate(cards_for_prompt)}
    MSG
  end


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

  # Quiz-mode addendum (user message, so prompt caching survives the toggle).
  # Asks the model to write questions that HAVE a right answer and mark it.
  def quiz_instruction
    <<~QUIZ

      QUIZ MODE — this Verto is a quiz. Favour questions that have a definite
      correct answer (facts, knowledge checks). For multiple_choice, yes_no,
      select_one_grid, select_many, select_many_grid and open_ended questions,
      set `correct` to the right answer(s) — exact option label(s), or one or
      more acceptable text answers for open_ended — and `explanation` to one
      short sentence. Leave range, nps, rating and tap_card UNGRADED (omit
      `correct`). A few ungraded opinion/measurement questions are fine where
      they fit naturally.
    QUIZ
  end

  # tool_use?, input_of, deep_stringify come from AnthropicHelpers.
end
