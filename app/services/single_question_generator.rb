require "anthropic"

# Generates a single new question card that complements an existing survey.
# Reuses SurveyGenerator's system prompt, CARD_TYPES, and QuestionCorpus.
class SingleQuestionGenerator
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 512

  TOOL = {
    name: "emit_question",
    description: "Emit a single new survey question card that fits the existing survey context.",
    input_schema: {
      type: "object",
      properties: {
        type: {
          type: "string",
          enum: SurveyGenerator::CARD_TYPES,
          description: "Card type — must not repeat either of the last two card types used."
        },
        text: {
          type: "string",
          description: "Question text. Target 50-70 chars; 100 hard max (text + any description <= 100)."
        },
        description: {
          type: "string",
          description: "Optional sub-text shown under the question."
        },
        options: {
          type: "array",
          items: { type: "string" },
          description: <<~DESC
            Required for: multiple_choice, select_many, select_one_grid,
            select_many_grid, prioritise, tap_card, range, rating, nps.
            Bounds (per the design rules): list types ODD 3 or 5 options
            (each <= 30 chars); grids EVEN and 4-10 including any "Other"
            (each <= 20 chars); prioritise 4-5 (4 ideal, each <= 30 chars);
            tap_card 5-8 statements (neg -> neutral -> pos, each <= 40
            chars); range EXACTLY 5 points with a neutral middle; rating 3-5 with
            one label per point; nps EXACTLY 11 numeric labels "0"-"10".
          DESC
        },
        competency: {
          type: "string",
          enum: Framework::COMPETENCY_KEYS,
          description: "OPTIONAL. The competency this question sits under: awareness, intention " \
                       "or agency. OMIT for purely descriptive or demographic questions."
        },
        outcome: {
          type: "string",
          description: "One plain-language sentence stating the insight this question's answers " \
                       "will give the creator. Always write one for a question card."
        },
        condition: {
          type: "string",
          enum: Framework::CONDITION_KEYS,
          description: "OPTIONAL. Set only when the question probes an enabling condition under " \
                       "agency (wellbeing, belonging, perceived_support, confidence_capability, " \
                       "institutional_responsiveness, safety_protection)."
        }
      },
      required: %w[type text]
    }
  }.freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # Returns a single card hash (string keys), e.g.:
  #   { "type" => "select_one_grid", "text" => "...", "options" => [...] }
  def call(theme:, audience_age:, key_insight:, existing_cards: [], locale: SupportedLocales::DEFAULT)
    # Types used in the last 2 cards — avoid consecutive repetition
    recent_types = Array(existing_cards).last(2).map { |c| c["type"].to_s }.compact.uniq
    last_type    = Array(existing_cards).last&.dig("type").to_s

    brief    = [ theme, audience_age, key_insight ].compact.join(" ")
    examples = QuestionCorpus.search(brief, limit: 4, min_overlap: 2)

    type_summary = Array(existing_cards).map { |c| c["type"] }.join(", ")

    user_message = +<<~MSG
      Survey context:
      Theme: #{theme}
      Target audience age: #{audience_age}
      Key insight: #{key_insight}

      This survey already has #{existing_cards.size} card(s).
      Card types in order: #{type_summary.presence || "(none yet)"}
      Last card type: #{last_type.presence || "(none)"}

      #{coverage_summary(existing_cards)}

      Generate exactly ONE new question that:
      - Fits the theme and audience
      - Does NOT use a type already used in the last 2 cards (#{recent_types.join(", ").presence || "none"})
      - Follows all survey design rules from the system prompt
      - Complements the existing questions without duplicating coverage
      - Strengthens the Awareness/Intention/Agency coverage above — prefer a
        question that fills a gap over more of what's already there

      Output via the emit_question tool.
    MSG

    if examples.any?
      user_message << "\nVocabulary reference (do NOT copy verbatim — adapt to this brief):\n"
      examples.each do |e|
        user_message << %(- "#{e[:question]}" [#{e[:primary_type]}]\n)
      end
    end

    user_message << <<~RULES

      Per-card design rules this new card must follow (deviate only if the
      brief truly requires it):
      #{SurveyGenerator::CARD_RULES}
      And do NOT reuse a type from the last 2 cards (#{recent_types.join(", ").presence || "none"}).
      Also give this card an `outcome` (one plain sentence naming the insight
      its answers give the creator), and tag `competency` / `condition` where
      they apply — see the Awareness/Intention/Agency guidance above.
    RULES

    unless locale.to_s == SupportedLocales::DEFAULT
      lang = SupportedLocales.find(locale)
      name = lang ? "#{lang.english_name} (#{lang.native_name})" : locale.to_s
      user_message << "\nLANGUAGE: Write the question text, any description and ALL option labels in #{name}. Do not use English.\n"
    end

    tool = TOOL.deep_dup
    tool[:input_schema][:properties][:type][:enum] = SurveyGenerator.generatable_types
    # Cache the static prefix (tool schema + the shared SurveyGenerator::SYSTEM).
    # This fires on every "add a question", so cache reads within the 5-min TTL
    # are the highest-ROI saving. Stays cacheable on Haiku (same ~2048 min).
    tool[:cache_control] = { type: "ephemeral" }

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      SurveyGenerator::SYSTEM,
      tools:       [ tool ],
      tool_choice: { type: "tool", name: "emit_question" },
      messages:    [ { role: "user", content: user_message } ]
    )
    log_usage("SingleQuestionGenerator", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    card = deep_stringify(input_of(block))
    # Trust nothing: drop a competency/condition that isn't a known Framework key.
    card.delete("competency") unless Framework.competency?(card["competency"])
    card.delete("condition")  unless Framework.condition?(card["condition"])
    card
  end

  private

  # A short nudge describing which Awareness/Intention/Agency competencies and
  # enabling conditions the existing deck already covers, so a single "add a
  # question" strengthens framework coverage (fills a gap) rather than piling on
  # more of the same. Reads the competency/condition tags now stored on cards
  # (older decks with no tags just yield a "none yet" summary).
  def coverage_summary(existing_cards)
    comps = Array(existing_cards).filter_map { |c| c["competency"].to_s.presence }
    conds = Array(existing_cards).filter_map { |c| c["condition"].to_s.presence }

    comp_counts = Framework::COMPETENCY_KEYS
                    .map { |k| "#{k}×#{comps.count(k)}" }.join(", ")
    missing = Framework::COMPETENCY_KEYS.reject { |k| comps.include?(k) }

    suggestions = []
    if comps.include?("agency") && conds.empty?
      suggestions << "the deck probes agency but has no enabling-condition question — " \
                     "a wellbeing or belonging question would make low agency explainable"
    end
    suggestions << "no #{missing.join(' or ')} question yet — one would help reveal the activation gap" if missing.any?
    suggestions << "otherwise deepen coverage where the theme most needs it" if suggestions.empty?

    "Framework coverage so far — competencies: #{comp_counts}; conditions: " \
    "#{conds.uniq.join(', ').presence || 'none'}. Prefer a question that fills a gap: " \
    "#{suggestions.join('; ')}."
  end

  # tool_use?, input_of, deep_stringify come from AnthropicHelpers.
end
