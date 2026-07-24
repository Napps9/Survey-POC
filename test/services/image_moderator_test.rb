require "test_helper"
require "ostruct"

class ImageModeratorTest < ActiveSupport::TestCase
  # 1x1 transparent PNG.
  PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  class FakeClient
    attr_reader :last_kwargs
    def initialize(safe:, reason: "")
      @safe = safe
      @reason = reason
    end
    def messages = self
    def create(**kwargs)
      @last_kwargs = kwargs
      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: { "safe" => @safe, "reason" => @reason }) ],
        usage: OpenStruct.new(input_tokens: 20, output_tokens: 5, cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end
  end

  def moderator_with(client)
    m = ImageModerator.allocate
    m.instance_variable_set(:@client, client)
    m
  end

  # Pops one canned response per `create` call. `:ambiguous` simulates a
  # response with no tool_use block at all (a model hedge/refusal); anything
  # else is a { safe:, reason: } verdict rendered as a well-formed tool call.
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
      verdict = @responses.shift
      content = verdict == :ambiguous ? [] : [ OpenStruct.new(type: "tool_use", input: { "safe" => verdict[:safe], "reason" => verdict[:reason] || "" }) ]
      OpenStruct.new(
        content: content,
        usage: OpenStruct.new(input_tokens: 20, output_tokens: 5, cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end
  end

  test "reports a safe image as safe and sends the image + audience to the model" do
    client = FakeClient.new(safe: true)
    out = moderator_with(client).call(data_url: PNG, audience_age: "under 10s")

    assert_equal({ safe: true, reason: "" }, out)
    content = client.last_kwargs[:messages].first[:content]
    img = content.find { |b| b[:type] == "image" }
    assert_equal "image/png", img[:source][:media_type]
    assert_includes client.last_kwargs[:system], "under 10s"
    assert_equal ClaudeModels::FAST, client.last_kwargs[:model]
  end

  test "reports an unsafe image with the reason" do
    out = moderator_with(FakeClient.new(safe: false, reason: "contains nudity")).call(data_url: PNG)
    assert_equal false, out[:safe]
    assert_equal "contains nudity", out[:reason]
  end

  test "passes through non-data-URLs and unsupported formats without calling the model" do
    client = FakeClient.new(safe: false, reason: "should not run")
    assert_equal({ safe: true, reason: "" }, moderator_with(client).call(data_url: "https://images.pexels.com/x.jpg"))
    assert_equal({ safe: true, reason: "" }, moderator_with(client).call(data_url: "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4="))
    assert_nil client.last_kwargs, "the model must not be called for unsupported input"
  end

  test "configured? follows the Anthropic key" do
    assert ImageModerator.configured? # test env sets a stub key
  end

  test "retries once on an ambiguous response, then returns the retry's safe verdict" do
    client = SequencedFakeClient.new([ :ambiguous, { safe: true, reason: "" } ])
    out = moderator_with(client).call(data_url: PNG)

    assert_equal({ safe: true, reason: "" }, out)
    assert_equal 2, client.call_count
  end

  test "retries once on an ambiguous response, then returns the retry's unsafe verdict" do
    client = SequencedFakeClient.new([ :ambiguous, { safe: false, reason: "contains alcohol" } ])
    out = moderator_with(client).call(data_url: PNG)

    assert_equal({ safe: false, reason: "contains alcohol" }, out)
    assert_equal 2, client.call_count
  end

  test "reports ambiguous rather than unsafe when both attempts lack a tool_use block" do
    client = SequencedFakeClient.new([ :ambiguous, :ambiguous ])
    out = moderator_with(client).call(data_url: PNG)

    assert_equal({ safe: false, reason: "", ambiguous: true }, out)
    assert_equal 2, client.call_count, "should retry exactly once, not loop"
  end
end
