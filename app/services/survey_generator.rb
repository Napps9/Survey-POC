require "anthropic"

class SurveyGenerator
  include AnthropicHelpers

  MODEL = ClaudeModels::DEFAULT
  MAX_TOKENS = 4096

  # Rules of the Game §3 — a tap_card carries 5-8 swipe statements.
  TAP_CARD_MIN_STATEMENTS = 5
  TAP_CARD_MAX_STATEMENTS = 8

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
          minItems: 12,
          maxItems: 15,
          description: "Ordered list. 12-15 cards TOTAL, including the single opening welcome_card.",
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
                items: { type: "string", description: "Each option label within its type's character budget (see the design rules)." },
                description: <<~DESC
                  Required for: multiple_choice, select_many, select_one_grid, select_many_grid,
                  prioritise, tap_card, range, rating, nps. Bounds (per the design rules):
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
              id: {
                type: "integer",
                description: "Echo back the id of a Common Question card supplied in the brief. Set only on those cards; leave unset on any new card you write."
              },
              competency: {
                type: "string",
                enum: Framework::COMPETENCY_KEYS,
                description: "OPTIONAL. The Acting-in-the-world competency this question sits under: " \
                             "awareness (what someone notices/feels/experiences), intention (readiness to " \
                             "be involved — desire, not yet action), or agency (what they feel capable of " \
                             "and have actually done). OMIT for purely descriptive or demographic questions."
              },
              outcome: {
                type: "string",
                description: "One plain-language sentence stating the insight this question's answers will " \
                             "give the creator (e.g. 'Shows how connected young people feel to their " \
                             "community right now'). Write one for EVERY question card. OMIT on welcome_card."
              },
              condition: {
                type: "string",
                enum: Framework::CONDITION_KEYS,
                description: "OPTIONAL. Set only when the question probes an enabling condition that sits " \
                             "underneath sustained agency: wellbeing (lived experience, not diagnosis), " \
                             "belonging, perceived_support, confidence_capability, " \
                             "institutional_responsiveness or safety_protection."
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
    - List types (multiple_choice / select_many): an ODD count — 3 or 5
      options, never an even count — each <= 30 chars.
    - Grids (select_one_grid / select_many_grid): EVEN option count, 4 to 10
      total including any "Other", each label <= 20 chars. Tiles sit 2
      across, so an even count keeps the grid balanced (2x2 up to ~3x4).
    - prioritise: 4 or 5 options (4 ideal), each <= 30 chars. Use when
      the ORDER of preference matters (rank these highest to lowest).
    - tap_card: 5 to 8 statement cards. Together the statements MUST cover
      a NEGATIVE, a NEUTRAL and a POSITIVE sentiment on the question's
      topic, ordered negative -> neutral -> positive (negatives first,
      positives last). Each statement is its own swipe card; the respondent
      swipes yes/no on each, and the combination reveals their sentiment.
      Keep each statement <= 40 characters.
    - range: an ODD count — 3 or 5 points (5 ideal), never an even count
      like 4 — so the scale always has a true centre point. That centre
      point's label must be genuinely neutral (e.g. "Neutral" / "Unsure" /
      "Neither agree nor disagree"), never leaning positive or negative.
      The slider starts resting on that neutral centre by default.
    - rating: 3 to 5 points (5 ideal — the visual is a 5-star row). Supply
      ONE label per point, not just the two end captions.
    - nps: the traditional 0-10 likelihood-to-recommend scale on a plain
      vertical slider. EXACTLY 11 options: the numeric labels "0" through
      "10" — no word labels.
    - Question text: 50-70 chars target, 100 hard max. Any description below the
      question SHARES that same 100-char budget (text + description <= 100).
    - "How often" questions: default to range with an odd count (3 or 5) and
      a neutral middle. If more are genuinely required, fall back rating ->
      multiple_choice -> select_one_grid; never exceed 5 options for a
      "How often" question.
  RULES

  # Awareness / Intention / Agency guidance injected into the prompt, built from
  # the Framework single source of truth so the wording can't drift from the
  # tool-schema enums or the editor's "Why" tab badges.
  FRAMEWORK_GUIDE = begin
    comps = Framework.competencies.map { |k, v| "      - #{k} — #{v['blurb']}" }.join("\n")
    conds = Framework.conditions.map   { |k, v| "      - #{k} — #{v['blurb']}" }.join("\n")
    <<~GUIDE.freeze
      6. Design for Awareness, Intention & Agency — Playverto reads the OECD
         "Acting in the world" competency as a sequence: Awareness -> Intention
         -> Agency -> Action. The point of a Verto is to reveal WHERE that
         sequence breaks (the "activation gap": aware but not acting, or ready
         but not able). So DESIGN the deck for it — don't just label whatever
         you happen to write:

         - Span the sequence. Where the theme supports it, include Awareness
           AND Intention AND Agency questions, so readiness (intention) can be
           read against real action (agency). Don't ship an all-Awareness deck
           when the theme could support intention and agency — that hides the
           gap. (Some themes are legitimately narrower; use judgement.)
         - Pair Agency with a Condition. Whenever the deck includes an Agency
           question, also include at least one enabling-condition question —
           especially wellbeing or belonging — so low agency is explainable
           ("agency is low here, and belonging looks like why"). Emotional
           wellbeing is often the bridge between caring and acting.
         - Comparability over time. Phrase questions with stable, repeatable
           wording so the same set can be re-run in 6-12 months and still
           compare — avoid one-off, date- or event-bound phrasing unless the
           brief requires it.
         - Legibility. Keep each question about ONE competency, so answers stay
           comparable across questions and themes.

         Then tag what you built:
         - Write an `outcome`: one plain-language sentence naming the insight
           the answers give the creator. Do this for EVERY question card (omit
           only on the welcome_card).
         - Tag `competency` where the question clearly sits under one:
      #{comps}
           Leave `competency` unset for purely descriptive or demographic
           questions — not every good question is one of the three, and that's
           fine.
         - Tag `condition` where the question measures an enabling condition
           that sits underneath sustained agency:
      #{conds}
           Phrase wellbeing questions as lived experience — how someone's day
           actually feels — never as diagnosis or screening.
    GUIDE
  end

  SYSTEM = <<~PROMPT.freeze
    You are a Verto designer. Given a brief, produce a Verto experience that
    strictly follows the rules below. Deviate only when the brief explicitly
    requires it, and in that case keep the deviation minimal. Echo the user's
    theme, audience_age, and key_insight into the output unchanged.

    Do's and Don'ts (deviate only when the brief explicitly requires it, and
    keep any deviation minimal):

    1. Length — Target 12 to 15 cards TOTAL, including the single opening
       welcome_card; never exceed 16. Fewer cards is not automatically
       better — a Verto needs enough breadth to be useful.

    2. Question definition — A "question" is anything the user must read and
       respond to. A range counts as 1 question. A tap_card counts as one
       card but as many questions as it has statements — so a 5-statement
       tap_card is 5 questions. Keep that weight in mind when pacing.

    3. Answer-type variety — Never place more than 2 of the same answer type in
       a row in the flow. Range, rating and nps are individual answer types
       for this rule and may sit back to back.

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
    option labels are too long to fit a tile (over ~14 characters).

    - select_one_grid (Verto "Pick One — image grid"): DEFAULT for single-
      pick questions. Visual tiles, 2 across (2×2 up to ~3×4), even option
      counts up to 10. Each tile can carry an image, icon, or coloured
      swatch — far more engaging than a plain list. Use this whenever
      options can be represented visually or fit short labels.
    - select_many_grid (Verto "Select Many — image grid"): DEFAULT for
      multi-pick questions. Same visual tile grid, multi-select. Even option
      counts up to 10. Use this whenever multiple answers can apply and
      options can be represented visually or fit short labels.
    - multiple_choice (Verto "Pick One — image list"): vertical list,
      single pick, with a small coloured tile on the left of each option.
      Use as the fallback when labels are too long for a grid tile
      (over ~14 chars). An ODD count — 3 or 5 options. Can include an
      "Other".
    - select_many (Verto "Select Many — image list"): same image-list
      layout, multi-pick. Use ONLY when select_many_grid won't fit (long
      labels). An ODD count — 3 or 5 options.
    - tap_card (Verto "Tap"): a swipe stack of 5 to 8 statements about
      the question's topic. Together the statements MUST express NEGATIVE,
      NEUTRAL and POSITIVE sentiments on the topic, ordered negative ->
      neutral -> positive. The respondent swipes yes/no on each; the
      combination reveals their stance. Each statement <= 40 characters.
      Best when you want quick gut reactions to a single subject from
      several angles.
    - range (Verto "Range"): playful ODD-count (3 or 5, 5 ideal) sliding
      scale for emotion or agree/disagree, ALWAYS with a genuinely neutral
      middle label — never an even count with no true centre. Lower and
      negative to the left, positive to the right, starting neutral in the
      middle. The left panel plays a reactive Lottie animation matched to
      the slider position — an engaging on-theme reaction. Use for mood,
      satisfaction, agreement — anything qualitative-scaled; prefer this
      when an engaging visual lifts response quality.
    - rating (Verto "Rating"): icon-based scale (stars by default, but icons
      can be customised). 3 to 5 points (5 ideal), ONE label per point. Use
      for "how good was X" questions. Can also stand in for range when
      familiar iconography matters more than the animation.
    - nps (Verto "NPS"): the traditional 0-10 likelihood-to-recommend scale
      on a plain vertical slider (no reaction animation). Use for
      likelihood-to-recommend or a straightforward sentiment/temperature
      check. EXACTLY 11 numeric labels, "0" through "10" — no word labels.
      Prefer range when an engaging on-theme reaction adds value.
    - yes_no: simple gating only. Use sparingly — a select_one_grid with
      two visual options is often richer.
    - open_ended (Verto "Freeform"): text input, can be voice-recorded too.
      Use sparingly to capture authentic qualitative voice.
    - prioritise (Verto "Prioritise"): a list respondents drag into an order
      of priority — highest to lowest (or most-to-least agree/liked). Use for
      explicit ranking questions ("In what order…", "Rank these…") where the
      ORDER of preference is the insight, not just which options are picked.
      4 or 5 options, 4 ideal.
    - welcome_card: not a question; flow control per the rules.

    #{FRAMEWORK_GUIDE}
    When relevant historical Playverto questions are provided in the brief,
    use them to inform wording style and answer-type selection. Do NOT copy
    them verbatim — adapt to the brief's audience and insight. The design
    rules above always override any pattern from the historical examples.

    Self-check before emitting — re-read your draft and fix any rule violation
    (unless the brief explicitly requires the exception):
    [ ] 12 to 15 cards TOTAL (welcome card included); starts with exactly 1 welcome card
    [ ] No more than 2 of the same answer type in a row
    [ ] Lists ODD 3 or 5 options (each <= 30 chars); grids EVEN and 4-10 (each <= 20 chars);
        prioritise 4-5 (4 ideal); tap_card 5-8 statements (neg -> neutral -> pos, each <= 40 chars);
        range ODD (3 or 5) with a genuine neutral middle label; rating 3-5 with one label per
        point; nps EXACTLY 11 numeric labels "0"-"10"
    [ ] Every question's text plus its description <= 100 chars
    [ ] "How often" -> range with an odd count (3 or 5) and a neutral middle
    [ ] Every question card has an `outcome`; competency/condition tagged where they apply
    [ ] The deck spans Awareness/Intention/Agency where the theme allows (not all one competency)
    [ ] Any Agency question is paired with an enabling-condition question (esp. wellbeing/belonging)
    [ ] Wording is stable enough to re-run in 6-12 months and still compare
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
      - 12 to 15 cards total, including the single opening welcome_card
      - no more than 2 of the same answer type in a row
      - DEFAULT every single-pick question to select_one_grid and every
        multi-pick to select_many_grid; only fall back to multiple_choice /
        select_many when option labels are over ~14 chars
      - tap_card 5-8 statements (neg -> neutral -> pos) · grids even count, ≤10
      - lists ODD 3 or 5 options · prioritise 4-5 · nps exactly "0"-"10"
      - question text 50-70 chars target, never exceed 100
      - option text ≤ 14 chars when using a grid; ≤ 30 chars in a text list
      - ALWAYS start with exactly one welcome_card that sets the scene
      - span Awareness -> Intention -> Agency where the theme allows (don't
        make an all-Awareness deck), and pair any Agency question with a
        wellbeing/belonging condition question so low agency is explainable
      - phrase for repeat measurement — stable wording that still compares if
        this Verto is re-run in 6-12 months
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
    enforce_tap_card_statement_bounds!(payload)
    ensure_welcome_card!(payload)
    reconcile_common_cards!(payload, common_cards)
    normalize_quiz_correct!(payload) if quiz
    normalize_framework!(payload)
    payload
  end

  # Trust nothing: drop any competency/condition the model invented that isn't a
  # known Framework key, so a stray value never reaches the editor's Why badges.
  # `outcome` is free-text and left as-is.
  def normalize_framework!(payload)
    Array(payload["cards"]).each do |card|
      card.delete("competency") unless Framework.competency?(card["competency"])
      card.delete("condition")  unless Framework.condition?(card["condition"])
    end
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

  # Belt-and-braces post-generation guard for the "tap_card must be 5-8
  # statements" rule. The system prompt asks Claude for this directly, but
  # Claude occasionally overshoots; trimming to the first 8 keeps the rule
  # strict without losing the ordering Claude already produced (the prompt
  # asks for negative → neutral → positive in index order). Short decks are
  # left alone — padding would invent statements the model never wrote.
  def enforce_tap_card_statement_bounds!(payload)
    Array(payload["cards"]).each do |card|
      next unless card["type"].to_s == "tap_card"
      opts = Array(card["options"])
      card["options"] = opts.first(TAP_CARD_MAX_STATEMENTS) if opts.size > TAP_CARD_MAX_STATEMENTS
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
      ENTIRE integrated deck (12-15 cards total, no more than 2 of the same
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
