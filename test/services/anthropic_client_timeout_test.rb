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
    OpenTextSummariser,
    # QuizAnswerGrader is reachable from #grade — public and unauthenticated —
    # so it is the one service respondent traffic can point at directly. It was
    # missing from this list, which is precisely the gap this test exists to
    # close. FlowGenerator and CardOptimiser are the editor-side equivalents.
    QuizAnswerGrader,
    FlowGenerator,
    CardOptimiser,
    NewsletterWriter
  ].freeze

  test "the shared Anthropic timeout is bounded well below the SDK default" do
    assert_operator AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS, :>, 0
    assert_operator AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS, :<,
                    Anthropic::Client::DEFAULT_TIMEOUT_IN_SECONDS,
                    "timeout must stay below the SDK's 600s default that caused the outage"
  end

  test "every Claude service builds its client with the bounded timeout and capped retries" do
    CLAUDE_SERVICES.each do |klass|
      service = klass.new(api_key: "test-key")
      # Services that build their client lazily (so a missing key degrades
      # instead of raising) have no @client until first use — force it.
      client = service.instance_variable_get(:@client) || service.send(:client)

      assert_equal AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS, client.timeout,
                   "#{klass} must build its Claude client through the bounded builder"
      assert_operator client.max_retries, :<=, Anthropic::Client::DEFAULT_MAX_RETRIES,
                      "#{klass} must cap Anthropic retries"
    end
  end
end
