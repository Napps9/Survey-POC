require "test_helper"
require "ostruct"

# Locks in the cost-optimisation wiring: prompt-cache breakpoints on the static
# prefixes, the correct model tier per service, and that usage logging reads the
# response without blowing up. These stub the client and capture the kwargs
# passed to messages.create, so no real API calls happen.
class AnthropicCostOptimisationTest < ActiveSupport::TestCase
  # Records the kwargs of the last messages.create call and replays a canned
  # tool_use response (with a usage object, like the real SDK).
  class CapturingClient
    attr_reader :last_kwargs

    def messages = self

    def create(**kwargs)
      @last_kwargs = kwargs
      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: { "cards" => [] }) ],
        usage: OpenStruct.new(input_tokens: 100, output_tokens: 10,
                              cache_creation_input_tokens: 100, cache_read_input_tokens: 0)
      )
    end
  end

  def capture(service)
    client = CapturingClient.new
    service.instance_variable_set(:@client, client)
    yield service
    client.last_kwargs
  end

  # Walks tools + system blocks and returns true if any carries an ephemeral
  # cache_control marker.
  def cached?(kwargs)
    blocks = Array(kwargs[:tools]) + Array(kwargs[:system])
    blocks.any? do |b|
      cc = b.is_a?(Hash) ? (b[:cache_control] || b["cache_control"]) : nil
      cc && (cc[:type] || cc["type"]).to_s == "ephemeral"
    end
  end

  test "SurveyGenerator caches the static prefix and uses the DEFAULT (Sonnet) model" do
    gen = SurveyGenerator.allocate
    kwargs = capture(gen) do |g|
      g.call(theme: "Sleep", audience_age: "18-24", key_insight: "habits")
    end
    assert_equal ClaudeModels::DEFAULT, kwargs[:model]
    assert cached?(kwargs), "expected an ephemeral cache_control breakpoint on tools/system"
  end

  test "SingleQuestionGenerator caches the static prefix and uses the FAST (Haiku) model" do
    gen = SingleQuestionGenerator.allocate
    kwargs = capture(gen) do |g|
      g.call(theme: "Sleep", audience_age: "18-24", key_insight: "habits", existing_cards: [])
    end
    assert_equal ClaudeModels::FAST, kwargs[:model]
    assert cached?(kwargs)
  end

  test "PdfQuestionImporter caches the system prompt and uses the DEFAULT (Sonnet) model" do
    importer = PdfQuestionImporter.allocate
    kwargs = capture(importer) { |i| i.call(pdf_data: "base64") }
    assert_equal ClaudeModels::DEFAULT, kwargs[:model]
    assert cached?(kwargs)
  end

  test "SurveyTranslator uses the FAST (Haiku) model" do
    translator = SurveyTranslator.allocate
    card = { "type" => "multiple_choice", "text" => "Hi", "description" => "", "options" => %w[A B] }
    kwargs = capture(translator) do |t|
      t.call(cards: [ card ], target_locale: "es", source_locale: "en")
    end
    assert_equal ClaudeModels::FAST, kwargs[:model]
  end

  test "model tiers are distinct so generation stays on Sonnet while cheap tasks move to Haiku" do
    assert_equal "claude-sonnet-4-6", ClaudeModels::DEFAULT
    assert_not_equal ClaudeModels::DEFAULT, ClaudeModels::FAST
    assert_match(/haiku/, ClaudeModels::FAST)
  end
end
