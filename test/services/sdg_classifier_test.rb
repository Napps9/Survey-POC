require "test_helper"
require "ostruct"

# SDG tags are enrichment: the contract under test is that classification can
# never break the import or seed that asked for it — junk output is sanitised,
# failures come back as [], and no key means no client is ever built.
class SdgClassifierTest < ActiveSupport::TestCase
  # Replays one canned tool_use response (or raises), recording the kwargs of
  # the create call so tests can assert what was actually sent.
  class ScriptedClient
    attr_reader :last_kwargs

    def initialize(input: nil, error: nil)
      @input = input
      @error = error
    end

    def messages = self

    def create(**kwargs)
      @last_kwargs = kwargs
      raise @error if @error

      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: @input) ],
        usage: OpenStruct.new(input_tokens: 10, output_tokens: 5,
                              cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end
  end

  # The client is memoized (`@client ||=`), so pre-setting it wins — the
  # OpenTextThemer stubbing pattern.
  def classifier_with(client)
    classifier = SdgClassifier.new(api_key: "test")
    classifier.instance_variable_set(:@client, client)
    classifier
  end

  def survey
    @survey ||= Survey.new(
      id: 1, title: "Youth climate worries", theme: "Climate Action",
      cards: [ { "type" => "range", "text" => "How worried are you about climate change?",
                 "options" => [ "Not at all", "Very worried" ] } ]
    )
  end

  test "model output is sanitised: duplicates, junk and strings reduce to sorted goal numbers" do
    client = ScriptedClient.new(input: { "sdgs" => [ 13, 3, 3, 99, "4", -2 ] })

    assert_equal [ 3, 4, 13 ], classifier_with(client).call(survey: survey)
  end

  test "a failed call returns [] rather than raising into the import" do
    client = ScriptedClient.new(error: RuntimeError.new("api down"))

    assert_equal [], classifier_with(client).call(survey: survey)
  end

  test "no API key means no tags and no client built" do
    original = ENV.delete("ANTHROPIC_API_KEY")
    classifier = SdgClassifier.new

    assert_not classifier.configured?
    assert_equal [], classifier.call(survey: survey)
    assert_nil classifier.instance_variable_get(:@client),
      "an unconfigured classifier must never construct a client"
  ensure
    ENV["ANTHROPIC_API_KEY"] = original
  end

  # SdgClassifier builds its client lazily, so it is deliberately absent from
  # AnthropicClientTimeoutTest's CLAUDE_SERVICES (which reads @client straight
  # after construction, like OpenTextThemer's absence). The outage guard those
  # bounds exist for still has to cover it — asserted here instead.
  test "the lazily built client carries the app-wide timeout and retry bounds" do
    client = SdgClassifier.new(api_key: "test-key").client

    assert_equal AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS, client.timeout
    assert_operator client.max_retries, :<=, Anthropic::Client::DEFAULT_MAX_RETRIES
  end

  test "classification is forced through the tool and sends creator-authored content" do
    client = ScriptedClient.new(input: { "sdgs" => [ 13 ] })
    classifier_with(client).call(survey: survey)

    kwargs = client.last_kwargs
    assert_equal({ type: "tool", name: "tag_sdgs" }, kwargs[:tool_choice])
    prompt = kwargs[:messages].first[:content]
    assert_includes prompt, "How worried are you about climate change?"
    assert_includes prompt, "Youth climate worries"
  end

  test "a survey with nothing to classify costs nothing" do
    client = ScriptedClient.new(input: { "sdgs" => [ 13 ] })

    assert_equal [], classifier_with(client).call(survey: Survey.new)
    assert_nil client.last_kwargs, "no digest, no call"
  end
end
