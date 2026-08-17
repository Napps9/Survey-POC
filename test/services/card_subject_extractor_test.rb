require "test_helper"
require "ostruct"

class CardSubjectExtractorTest < ActiveSupport::TestCase
  CARDS = [
    { "type" => "welcome_card", "text" => "Welcome" },
    { "type" => "open_ended", "text" => "How was the school canteen?" },
    { "type" => "multiple_choice", "text" => "Gender", "demographic" => true,
      "options" => [ "Male", "Female", "Other" ] },
    { "type" => "yes_no", "text" => "Do you feel safe walking home at night?", "options" => %w[Yes No] }
  ].freeze

  class FakeClient
    attr_reader :last_kwargs
    def initialize(subjects:)
      @subjects = subjects
    end
    def messages = self
    def create(**kwargs)
      @last_kwargs = kwargs
      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: { "subjects" => @subjects }) ],
        usage: OpenStruct.new(input_tokens: 40, output_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end
  end

  # Pops one canned response per `create` call, same shape as
  # ImageModeratorTest's — :blank simulates a response with no tool_use block
  # at all (a model hedge/refusal).
  class SequencedFakeClient
    attr_reader :call_count, :last_kwargs
    def initialize(responses)
      @responses = responses.dup
      @call_count = 0
    end
    def messages = self
    def create(**kwargs)
      @call_count += 1
      @last_kwargs = kwargs
      subjects = @responses.shift
      content = subjects == :blank ? [] : [ OpenStruct.new(type: "tool_use", input: { "subjects" => subjects }) ]
      OpenStruct.new(
        content: content,
        usage: OpenStruct.new(input_tokens: 40, output_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end
  end

  def extractor_with(client)
    e = CardSubjectExtractor.allocate
    e.instance_variable_set(:@client, client)
    e
  end

  test "configured? follows the Anthropic key" do
    assert CardSubjectExtractor.configured? # test env sets a stub key
  end

  test "stamps subject onto eligible cards and leaves scaffolding/demographic cards alone" do
    client = FakeClient.new(subjects: [
      { "index" => 1, "subject" => "school canteen" },
      { "index" => 3, "subject" => "walking home at night" }
    ])
    out = extractor_with(client).call(cards: CARDS)

    assert_nil out[0]["subject"], "welcome_card has no depictable subject of its own"
    assert_equal "school canteen", out[1]["subject"]
    assert_nil out[2]["subject"], "the demographic card must never be sent a subject"
    assert_equal "walking home at night", out[3]["subject"]
  end

  test "only sends eligible (question, non-demographic) cards to the model" do
    client = FakeClient.new(subjects: [])
    extractor_with(client).call(cards: CARDS)

    sent = client.last_kwargs[:messages].first[:content]
    assert_includes sent, "How was the school canteen?"
    assert_includes sent, "Do you feel safe walking home at night?"
    refute_includes sent, "Welcome", "scaffolding cards have no subject of their own — must not be sent"
    refute_includes sent, "Gender", "the demographic card's own copy must never be sent"
  end

  test "an empty subject from the model is never stamped" do
    client = FakeClient.new(subjects: [ { "index" => 1, "subject" => "" } ])
    out = extractor_with(client).call(cards: CARDS)

    assert_nil out[1]["subject"], "an empty verdict must not overwrite with a blank string"
  end

  test "no eligible cards means no model call at all" do
    client = FakeClient.new(subjects: [])
    cards = [ { "type" => "welcome_card", "text" => "Welcome" } ]
    out = extractor_with(client).call(cards: cards)

    assert_equal cards, out
    assert_nil client.last_kwargs, "a deck with nothing depictable must not spend a call"
  end

  test "retries once when the first response has no tool_use block" do
    client = SequencedFakeClient.new([ :blank, [ { "index" => 1, "subject" => "school canteen" } ] ])
    out = extractor_with(client).call(cards: CARDS)

    assert_equal "school canteen", out[1]["subject"]
    assert_equal 2, client.call_count
  end

  test "returns cards unchanged, not raise, when both attempts have no tool_use block" do
    client = SequencedFakeClient.new([ :blank, :blank ])
    out = extractor_with(client).call(cards: CARDS)

    assert_equal CARDS, out
    assert_equal 2, client.call_count, "should retry exactly once, not loop"
  end

  test "a raised error from the client is swallowed, not propagated" do
    client = Object.new
    client.define_singleton_method(:messages) { self }
    client.define_singleton_method(:create) { |**_kw| raise "network blip" }

    out = nil
    assert_nothing_raised { out = extractor_with(client).call(cards: CARDS) }
    assert_equal CARDS, out
  end
end
