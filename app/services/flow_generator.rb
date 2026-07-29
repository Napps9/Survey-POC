require "anthropic"

# Generates a NAMED FLOW — a short, ordered group of question cards for one
# audience segment (e.g. the UK branch of "Which region are you in?") — from a
# creator prompt. The sibling of SingleQuestionGenerator one level up: same
# shared SurveyGenerator::SYSTEM + CARD_RULES so the flow's cards obey the
# same Rules of the Game the editor scores, same FAST model tier (a flow is a
# well-constrained ask: 3-6 cards on one narrow topic).
class FlowGenerator
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 2048
  MIN_CARDS  = 3
  MAX_CARDS  = 6

  CARD_SCHEMA = {
    type: "object",
    properties: {
      type: {
        type: "string",
        enum: SurveyGenerator::CARD_TYPES,
        description: "Card type. Vary types across the flow — never two consecutive cards of the same type."
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
  }.freeze

  TOOL = {
    name: "emit_flow",
    description: "Emit a named branch flow: a short ordered group of question cards asked only " \
                 "to the audience segment that enters it.",
    input_schema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Short flow name (<= 60 chars) matching the segment, e.g. 'UK' — " \
                       "reuse the entry answer's wording when one is given."
        },
        cards: {
          type: "array",
          minItems: MIN_CARDS,
          maxItems: MAX_CARDS,
          items: CARD_SCHEMA,
          description: "The flow's question cards, in the order the segment will see them."
        }
      },
      required: %w[name cards]
    }
  }.freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # Returns { "name" => "UK", "cards" => [<card hash>, ...] } (string keys).
  # `answer`/`entry_text` carry the routing context when the flow is being
  # created for a specific answer of a specific question.
  def call(prompt:, theme:, audience_age:, key_insight:, answer: nil, entry_text: nil,
           existing_cards: [], locale: SupportedLocales::DEFAULT)
    type_summary = Array(existing_cards).map { |c| c["type"] }.join(", ")

    user_message = +<<~MSG
      Survey context:
      Theme: #{theme}
      Target audience age: #{audience_age}
      Key insight: #{key_insight}

      The survey already has #{existing_cards.size} card(s). Card types in order: #{type_summary.presence || "(none yet)"}

      You are generating a BRANCH FLOW — a short group of #{MIN_CARDS}-#{MAX_CARDS} question cards that
      only one segment of respondents will see. The rest of the deck stays as it is; the flow
      converges back afterwards, so it must stand alone and stay focused.
    MSG

    if answer.present?
      user_message << "\nThis flow opens when a respondent answers \"#{answer}\"" \
                      "#{entry_text.present? ? " to \"#{entry_text}\"" : ""} — name it after that segment and " \
                      "write every card for that segment specifically.\n"
    end

    user_message << <<~MSG

      The creator's brief for this flow:
      #{prompt}

      Requirements:
      - Every card is about the flow's segment/topic — no generic filler
      - Vary answer types: never two consecutive cards of the same type, and don't open with
        the type the main deck uses most
      - Follow all survey design rules from the system prompt

      Per-card design rules every card must follow (deviate only if the brief truly requires it):
      #{SurveyGenerator::CARD_RULES}
      Also give each question card an `outcome` (one plain sentence naming the insight its
      answers give the creator), and tag `competency` / `condition` where they apply.

      Output via the emit_flow tool.
    MSG

    unless locale.to_s == SupportedLocales::DEFAULT
      lang = SupportedLocales.find(locale)
      name = lang ? "#{lang.english_name} (#{lang.native_name})" : locale.to_s
      user_message << "\nLANGUAGE: Write the flow name, all question text, descriptions and ALL option labels in #{name}. Do not use English.\n"
    end

    tool = TOOL.deep_dup
    tool[:input_schema][:properties][:cards][:items][:properties][:type][:enum] = SurveyGenerator.generatable_types
    # Cache the static prefix (tool schema + the shared SurveyGenerator::SYSTEM),
    # same as SingleQuestionGenerator — repeated flow generations in one editing
    # session hit the cache.
    tool[:cache_control] = { type: "ephemeral" }

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      SurveyGenerator::SYSTEM,
      tools:       [ tool ],
      tool_choice: { type: "tool", name: "emit_flow" },
      messages:    [ { role: "user", content: user_message } ]
    )
    log_usage("FlowGenerator", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    result = deep_stringify(input_of(block))
    cards = Array(result["cards"]).filter_map do |card|
      next unless card.is_a?(Hash)
      next if card["text"].to_s.strip.blank?
      next unless SurveyGenerator.generatable_types.include?(card["type"].to_s)
      # Trust nothing: drop a competency/condition that isn't a known Framework key.
      card.delete("competency") unless Framework.competency?(card["competency"])
      card.delete("condition")  unless Framework.condition?(card["condition"])
      card
    end.first(MAX_CARDS)
    raise "Model returned no usable cards" if cards.empty?

    { "name" => result["name"].to_s.strip.first(Survey::MAX_FLOW_NAME).presence || answer.to_s.presence || "Flow",
      "cards" => cards }
  end
end
