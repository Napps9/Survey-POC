require "anthropic"

class SurveyGenerator
  MODEL = "claude-sonnet-4-6"
  MAX_TOKENS = 4096

  TOOL = {
    name: "emit_survey",
    description: "Emit a structured survey based on the user's described goal.",
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Short survey title" },
        description: { type: "string", description: "1-2 sentence intro shown to respondents" },
        questions: {
          type: "array",
          minItems: 3,
          items: {
            type: "object",
            properties: {
              text: { type: "string" },
              type: {
                type: "string",
                enum: %w[multiple_choice rating open_ended yes_no]
              },
              options: {
                type: "array",
                items: { type: "string" },
                description: "Required when type is multiple_choice; otherwise omit."
              }
            },
            required: %w[text type]
          }
        }
      },
      required: %w[title description questions]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You design clear, unbiased survey questions. Given a user's goal, produce a
    concise survey with a sensible mix of question types. Prefer specific,
    actionable wording; avoid leading or double-barreled questions. Use
    multiple_choice when the answer space is well-defined; rating for
    satisfaction or agreement scales; yes_no for simple gating; open_ended
    sparingly for qualitative depth.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
  end

  def call(prompt)
    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: [TOOL],
      tool_choice: { type: "tool", name: "emit_survey" },
      messages: [{ role: "user", content: prompt }]
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
