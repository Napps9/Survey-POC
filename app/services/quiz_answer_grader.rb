require "anthropic"

# Judges whether a respondent's free-text quiz answer genuinely matches the
# intent of one of a card's accepted answers, allowing for wording, grammar
# and typo differences a plain exact-match check ("make the laws" vs. the
# accepted "make laws") would wrongly mark wrong. Called from
# PlayerController#grade ONLY as a fallback when the exact match already
# fails, and only the first time a card is graded — see that controller for
# why this never gets invoked more than once per answer.
class QuizAnswerGrader
  include AnthropicHelpers

  MODEL      = ClaudeModels::FAST
  MAX_TOKENS = 64

  TOOL = {
    name: "grade_open_answer",
    description: "Judge whether a respondent's free-text quiz answer is a genuine match for any of the accepted answers.",
    input_schema: {
      type: "object",
      properties: {
        correct: {
          type: "boolean",
          description: "True only if the respondent's answer means the same thing as at least one accepted answer — minor rewording, grammar, articles, typos and synonyms are fine. False if it's off-topic, incomplete, opposite, or blank."
        }
      },
      required: %w[correct]
    }
  }.freeze

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = build_anthropic_client(api_key)
  end

  # Never raises — any network/parse error grades as false, i.e. the
  # respondent keeps the exact-match verdict they already had.
  def call(question:, accepted_answers:, answer:)
    q = question.to_s.strip
    a = answer.to_s.strip
    accepted = Array(accepted_answers).map(&:to_s).reject(&:empty?)
    return false if q.blank? || a.blank? || accepted.empty?

    user_message = <<~MSG
      Question: #{q}
      Accepted answers (matching any one counts as correct): #{accepted.join(" | ")}
      Respondent's answer: #{a}

      Does the respondent's answer genuinely match the intent of at least one
      accepted answer? Allow minor rewording, grammar, articles ("the"/"a"),
      typos and synonyms — but not a different or incomplete meaning.
    MSG

    response = @client.messages.create(
      model: MODEL,
      max_tokens: MAX_TOKENS,
      tools: [ TOOL ],
      tool_choice: { type: "tool", name: "grade_open_answer" },
      messages: [ { role: "user", content: user_message } ]
    )
    log_usage("QuizAnswerGrader", response.usage, model: MODEL)

    block = Array(response.content).find { |b| tool_use?(b) }
    return false unless block
    deep_stringify(input_of(block))["correct"] == true
  rescue => e
    Rails.logger.error("[QuizAnswerGrader] #{e.class}: #{e.message}")
    false
  end
end
