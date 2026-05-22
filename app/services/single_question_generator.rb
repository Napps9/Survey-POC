require "anthropic"

# Generates a single new question card that complements an existing survey.
# Reuses SurveyGenerator's system prompt, CARD_TYPES, and QuestionCorpus.
class SingleQuestionGenerator
  MODEL      = "claude-sonnet-4-6"
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
            select_many_grid, tap_card, range, rating. Bounds (per the design
            rules): list types 3-5 options (each <= 20 chars); grids EVEN and
            4-10 including any "Other"; tap_card 3-5; range/rating 3-5, never
            more than 5.
          DESC
        }
      },
      required: %w[type text]
    }
  }.freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
  end

  # Returns a single card hash (string keys), e.g.:
  #   { "type" => "select_one_grid", "text" => "...", "options" => [...] }
  def call(theme:, audience_age:, key_insight:, existing_cards: [])
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

      Generate exactly ONE new question that:
      - Fits the theme and audience
      - Does NOT use a type already used in the last 2 cards (#{recent_types.join(", ").presence || "none"})
      - Follows all survey design rules from the system prompt
      - Complements the existing questions without duplicating coverage

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
    RULES

    tool = TOOL.deep_dup
    tool[:input_schema][:properties][:type][:enum] = SurveyGenerator.generatable_types

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      SurveyGenerator::SYSTEM,
      tools:       [ tool ],
      tool_choice: { type: "tool", name: "emit_question" },
      messages:    [ { role: "user", content: user_message } ]
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
