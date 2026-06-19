require "test_helper"
require "ostruct"

# The Optimise CTA rewrites a flagged card without changing its answer type and
# feeds the editor's issues into the prompt. Stubs the client so no API is hit.
class CardOptimiserTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :last_kwargs
    def messages = self
    def create(**kwargs)
      @last_kwargs = kwargs
      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: {
          # The model tries to change the type — the service must override it.
          "type"    => "open_ended",
          "text"    => "Which of these sports do you most enjoy watching on TV?",
          "options" => %w[Football Rugby Cricket Tennis]
        }) ],
        usage: OpenStruct.new(input_tokens: 50, output_tokens: 10,
                              cache_creation_input_tokens: 50, cache_read_input_tokens: 0)
      )
    end
  end

  test "optimise keeps the original type, sends the issues, and uses the FAST cached model" do
    opt = CardOptimiser.allocate
    client = FakeClient.new
    opt.instance_variable_set(:@client, client)

    card = { "type" => "multiple_choice", "text" => "Sport?", "options" => %w[A B] }
    out  = opt.call(card: card, issues: [ "Only 2 answers — aim for 3-5." ],
                    theme: "Sport", audience_age: "under 25", key_insight: "tastes")

    assert_equal "multiple_choice", out["type"], "the optimiser must never change the answer type"
    assert_equal %w[Football Rugby Cricket Tennis], out["options"]
    assert_equal ClaudeModels::FAST, client.last_kwargs[:model]

    msg = client.last_kwargs[:messages].first[:content]
    assert_match "Only 2 answers", msg, "the flagged issue is in the prompt"
    assert_match "multiple_choice", msg, "the current type is pinned in the prompt"
    # The static prefix (tool schema + system) is cached.
    assert(Array(client.last_kwargs[:tools]).any? { |tl| tl.dig(:cache_control, :type) == "ephemeral" })
  end
end
