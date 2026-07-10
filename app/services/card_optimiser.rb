require "anthropic"

# Rewrites ONE existing question card so it satisfies the Rules of the Game,
# fixing the specific issues the editor's traffic-light analysis flagged —
# without changing the answer type or the question's intent. Powers the score
# board's "Optimise" CTA. Reuses SurveyGenerator's system prompt + per-card rules
# so the editor's live checks and the AI rewrite can't drift apart.
class CardOptimiser
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 512

  TOOL = {
    name: "emit_optimised_question",
    description: "Emit an improved version of the given survey question that fixes the listed issues while keeping the same intent and answer type.",
    input_schema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "Improved question text. 50-70 chars target; text + any description <= 100 hard max."
        },
        description: {
          type: "string",
          description: "Optional sub-text under the question; shares the 100-char budget. Omit if not needed."
        },
        options: {
          type: "array",
          items: { type: "string" },
          description: "Improved answer option labels obeying the per-type count + length bounds in the rules. Omit for types without options (yes_no, open_ended, welcome_card)."
        },
        outcome: {
          type: "string",
          description: "The card's `outcome` line (one plain sentence naming the insight its " \
                       "answers give the creator), refreshed to match the rewritten wording. " \
                       "Keep the same measurement intent; omit if the current one still fits."
        }
      },
      required: %w[text]
    }
  }.freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # `card` is the current card hash (string keys: type, text, description,
  # options). `issues` is an array of human-readable problems from the editor.
  # Returns the optimised card hash with the answer type preserved.
  def call(card:, issues: [], theme: nil, audience_age: nil, key_insight: nil, locale: SupportedLocales::DEFAULT)
    type   = card["type"].to_s
    issues = Array(issues).map(&:to_s).reject(&:blank?)
    opts   = Array(card["options"]).map(&:to_s).reject(&:blank?)

    user_message = +<<~MSG
      Improve ONE existing survey question. Keep the SAME answer type (#{type})
      and the SAME topic and intent — rewrite only to fix the issues below and to
      satisfy the design rules. Do not turn it into a different question.

      Survey context:
      Theme: #{theme}
      Target audience age: #{audience_age}
      Key insight: #{key_insight}

      Current question (type: #{type}):
      Text: #{card["text"]}
      #{"Description: #{card['description']}" if card['description'].present?}
      #{"Options: #{opts.join(' | ')}" if opts.any?}
      #{"Current outcome (refresh to match your rewrite): #{card['outcome']}" if card['outcome'].present?}

      Keep this question's competency/condition tagging as-is — only its wording,
      options and `outcome` line may change.

      Issues to fix:
      #{issues.any? ? issues.map { |i| "- #{i}" }.join("\n") : '- Make it fully comply with the design rules.'}

      Per-card design rules to satisfy:
      #{SurveyGenerator::CARD_RULES}

      Keep option labels meaningful (never "Option A"). Preserve options that
      already comply; add, trim or clarify only as the issues require. Keep any
      wellbeing framing as lived experience (never diagnosis/screening) and use
      stable wording that still compares if this Verto is re-run later. Output
      via the emit_optimised_question tool.
    MSG

    unless locale.to_s == SupportedLocales::DEFAULT
      lang = SupportedLocales.find(locale)
      name = lang ? "#{lang.english_name} (#{lang.native_name})" : locale.to_s
      user_message << "\nLANGUAGE: Write the question text, any description and ALL option labels in #{name}. Do not use English.\n"
    end

    tool = TOOL.deep_dup
    # Cache the static prefix (tool schema + the shared SurveyGenerator::SYSTEM),
    # which repeats across every Optimise click within the 5-min TTL.
    tool[:cache_control] = { type: "ephemeral" }

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      SurveyGenerator::SYSTEM,
      tools:       [ tool ],
      tool_choice: { type: "tool", name: "emit_optimised_question" },
      messages:    [ { role: "user", content: user_message } ]
    )
    log_usage("CardOptimiser", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    out = deep_stringify(input_of(block))
    out["type"] = type # never let the optimiser change the answer type
    out
  end

  private

  # tool_use?, input_of, deep_stringify come from AnthropicHelpers.
end
