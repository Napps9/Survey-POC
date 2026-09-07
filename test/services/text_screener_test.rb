require "test_helper"
require "ostruct"

class TextScreenerTest < ActiveSupport::TestCase
  # Pops one canned response per create call. A Hash is rendered as the tool
  # input; :ambiguous is a response with no tool_use block; an Exception class
  # is raised.
  class FakeClient
    attr_reader :calls

    def initialize(responses)
      @responses = responses.dup
      @calls = []
    end

    def messages = self

    def create(**kwargs)
      @calls << kwargs
      canned = @responses.shift
      raise canned, "boom" if canned.is_a?(Class) && canned <= Exception

      content = canned == :ambiguous ? [] : [ OpenStruct.new(type: "tool_use", input: canned) ]
      OpenStruct.new(content: content,
                     usage: OpenStruct.new(input_tokens: 50, output_tokens: 20,
                                           cache_creation_input_tokens: 0, cache_read_input_tokens: 0))
    end
  end

  def screener_with(*responses)
    client = FakeClient.new(responses)
    s = TextScreener.allocate
    s.instance_variable_set(:@client, client)
    [ s, client ]
  end

  ITEMS = [
    { index: 1, text: "I want cleaner parks", question: "What would you change?" },
    { index: 2, text: "My name is Carlos Pérez and I live at 12 Calle Mayor", question: "Anything else?" }
  ].freeze

  test "returns one verdict per index, with certainty clamped into range" do
    s, client = screener_with(
      "verdicts" => [
        { "index" => 1, "category" => "clean", "certainty" => 0.97 },
        { "index" => 2, "category" => "identifying", "certainty" => 1.4, "note" => "full name and street address" }
      ]
    )

    out = s.call(ITEMS, audience_age: "under 16s")

    assert out[:ok]
    assert_equal "clean", out[:verdicts][1].category
    assert_in_delta 0.97, out[:verdicts][1].certainty
    assert_equal "identifying", out[:verdicts][2].category
    assert_equal 1.0, out[:verdicts][2].certainty
    assert_equal "full name and street address", out[:verdicts][2].note
    assert_equal 1, client.calls.size
  end

  test "sends the audience, the question, and the text wrapped as respondent data" do
    s, client = screener_with("verdicts" => [ { "index" => 1, "category" => "clean", "certainty" => 0.9 } ])

    s.call(ITEMS.first(1), audience_age: "under 16s")

    kwargs = client.calls.first
    assert_equal ClaudeModels::FAST, kwargs[:model]
    assert_equal({ type: "tool", name: "report_text_screen" }, kwargs[:tool_choice])
    assert_includes kwargs[:system], "under 16s"
    assert_includes kwargs[:system], PromptSafety::INSTRUCTION.strip
    body = kwargs[:messages].first[:content]
    assert_includes body, "What would you change?"
    assert_includes body, "<#{PromptSafety::TAG}>I want cleaner parks</#{PromptSafety::TAG}>"
    assert_equal({ timeout: AnthropicHelpers::ANTHROPIC_TIMEOUT_SECONDS }, kwargs[:request_options])
  end

  test "drops verdicts for unknown indices or categories rather than guessing" do
    s, _client = screener_with(
      "verdicts" => [
        { "index" => 1, "category" => "clean", "certainty" => 0.9 },
        { "index" => 7, "category" => "clean", "certainty" => 0.9 },
        { "index" => 2, "category" => "rude", "certainty" => 0.9 },
        "garbage"
      ]
    )

    out = s.call(ITEMS)

    assert out[:ok]
    assert_equal [ 1 ], out[:verdicts].keys
  end

  test "retries once when the response has no verdict block" do
    s, client = screener_with(:ambiguous, "verdicts" => [ { "index" => 1, "category" => "clean", "certainty" => 0.9 } ])

    out = s.call(ITEMS.first(1))

    assert out[:ok]
    assert_equal 2, client.calls.size
  end

  test "reports failure, not a verdict, when both attempts are ambiguous" do
    s, client = screener_with(:ambiguous, :ambiguous)

    out = s.call(ITEMS)

    assert_equal false, out[:ok]
    assert_match(/no verdict/, out[:error])
    assert_equal 2, client.calls.size, "exactly one retry"
  end

  test "never raises: a transport error comes back as ok: false" do
    s, _client = screener_with(Timeout::Error)

    out = s.call(ITEMS)

    assert_equal false, out[:ok]
    assert_includes out[:error], "Timeout::Error"
  end

  test "an empty batch makes no call" do
    s, client = screener_with

    assert_equal({ ok: true, verdicts: {} }, s.call([]))
    assert_empty client.calls
  end
end
