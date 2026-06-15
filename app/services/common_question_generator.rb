require "anthropic"

# Generates a draft set of Common Questions — reusable question texts that
# users attach to multiple Vertos. Inputs are a theme and a key insight,
# output is a short name + 4-6 neutral question texts the user can edit.
#
# This generator does NOT pick types or options — that's the classifier's
# job (QuestionTypeClassifier), which runs on the texts produced here. Keeps
# this prompt small, fast and reusable: one model call per shape of work.
class CommonQuestionGenerator
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 1024

  TOOL = {
    name: "emit_question_set",
    description: "Emit a draft Common Questions set: a short label and 4-6 neutral, reusable question texts.",
    input_schema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Short, evergreen label for the set (3-5 words). Avoid the word 'Survey'."
        },
        description: {
          type: "string",
          description: "Optional one-line summary of what the set captures."
        },
        questions: {
          type: "array",
          minItems: 4,
          maxItems: 6,
          description: "4-6 question texts in the order they should appear in the set.",
          items: {
            type: "object",
            properties: {
              text: { type: "string", description: "Question text. Target 50-70 chars; 100 hard max." }
            },
            required: %w[text]
          }
        }
      },
      required: %w[name questions]
    }
  }.freeze

  # The "Rules of the Game" subset that applies to a single question card —
  # per SurveyGenerator::SYSTEM, only the per-card rules carry over to a
  # standalone set (flow-level rules like 10-15 total and no-two-of-a-type-
  # in-a-row only mean something when the questions sit inside a full Verto).
  SYSTEM = <<~PROMPT.freeze
    You draft "Common Questions" — short, reusable survey questions a team will
    attach to many different Vertos over time. Your only output is the set's
    name plus 4-6 question texts (one model picks types separately later).

    These rules apply (deviate only when the brief explicitly requires it):

    1. 4-6 questions per set. Never fewer, never more.
    2. No welcome cards — welcome is Verto-level flow control, not a question.
    3. Length: each question's text targets 50-70 characters, 100 hard max.
       Keep it readable on a phone.
    4. Neutral framing — the same question may appear in many different
       Vertos. Avoid wording that locks it into a single audience, brand or
       context. Prefer "Right now, how supported do you feel?" over
       "How supported do you feel by the Acme Corp wellbeing team?".
    5. Cover distinct angles. Don't ask the same thing twice in different
       words. Build a small, balanced battery.
    6. Echo the user's theme/insight back into the set name so it's easy
       to find in a list later.

    Output via the emit_question_set tool. Write in the target language given
    in the user message.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # Returns a string-keyed hash:
  #   { "name" => "...", "description" => "...", "questions" => [{"text"=>"..."}, ...] }
  def call(theme:, key_insight:, locale: SupportedLocales::DEFAULT)
    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      [ { type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } } ],
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "emit_question_set" },
      messages: [ {
        role: "user",
        content: <<~MSG
          Target language: #{locale}.

          Theme: #{theme}
          Key insight: #{key_insight}

          Draft a Common Questions set for this brief: a short name plus 4-6
          neutral, reusable questions that gather signal toward the key insight
          and would still read naturally if dropped into a different Verto on a
          related theme.
        MSG
      } ]
    )

    log_usage("CommonQuestionGenerator", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    payload = deep_stringify(input_of(block))
    payload["questions"] = Array(payload["questions"]).filter_map do |q|
      next unless q.is_a?(Hash)
      text = q["text"].to_s.strip
      next if text.empty?
      { "text" => text }
    end
    payload
  end
end
