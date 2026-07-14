require "test_helper"

# Regression guard for the app-wide 502 outage: a stuck Claude call must never
# hold a Puma request thread for the SDK's default 600 seconds. With only three
# threads on the starter instance, a few such calls exhaust the pool and Render
# returns 502 for *every* request — even pages that never touch Claude. Every
# service that talks to Claude must build its client through the shared,
# bounded-timeout AnthropicHelpers builder.
class AnthropicClientTimeoutTest < ActiveSupport::TestCase
  CLAUDE_SERVICES = [
    SurveyGenerator,
    SingleQuestionGenerator,
    SurveyTranslator,
    PdfQuestionImporter,
    CommonQuestionGenerator,
    QuestionTypeClassifier,
    ResultsSummariser,
    ResultsChat,
    OpenTextSummariser
  ].freeze

  test "the shared Anthropic timeout is bounded well below the SDK default" do
    assert_operator AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS, :>, 0
    assert_operator AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS, :<,
                    Anthropic::Client::DEFAULT_TIMEOUT_IN_SECONDS,
                    "timeout must stay below the SDK's 600s default that caused the outage"
  end

  test "every Claude service builds its client with the bounded timeout and capped retries" do
    CLAUDE_SERVICES.each do |klass|
      client = klass.new(api_key: "test-key").instance_variable_get(:@client)

      assert_equal AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS, client.timeout,
                   "#{klass} must build its Claude client through the bounded builder"
      assert_operator client.max_retries, :<=, Anthropic::Client::DEFAULT_MAX_RETRIES,
                      "#{klass} must cap Anthropic retries"
    end
  end
end
