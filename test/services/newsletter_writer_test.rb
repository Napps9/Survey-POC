require "test_helper"
require "ostruct"

# The house fake-client pattern: a local class implementing messages -> self,
# injected over @client so no key is needed and no request is made.
class NewsletterWriterTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :last_kwargs

    def initialize(input)
      @input = input
    end

    def messages = self

    def create(**kwargs)
      @last_kwargs = kwargs
      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: @input) ],
        usage: OpenStruct.new(input_tokens: 100, output_tokens: 50,
                              cache_creation_input_tokens: 0, cache_read_input_tokens: 100)
      )
    end
  end

  class ExplodingClient
    def messages = self
    def create(**) = raise(StandardError, "upstream is down")
  end

  GOOD = {
    "subject" => "Three things got easier",
    "preheader" => "A short note.",
    "intro" => "Here's the week.",
    "items" => [ { "title" => "Faster imports", "body" => "They just work." } ],
    "cta_label" => "Open VertoNow",
    "sign_off" => "Tell us what's next."
  }.freeze

  COMMITS = [ { "subject" => "The importer learns to count", "body" => "Why it mattered." } ].freeze
  WEEK = Date.new(2026, 8, 10)

  def writer_with(input)
    writer = NewsletterWriter.new(api_key: "test-key")
    client = FakeClient.new(input)
    writer.instance_variable_set(:@client, client)
    [ writer, client ]
  end

  test "composes copy and sends a cached system prompt with forced tool use" do
    writer, client = writer_with(GOOD)
    copy = writer.call(COMMITS, week: WEEK)

    assert_equal "Three things got easier", copy["subject"]
    assert_equal "Faster imports", copy["items"].first["title"]
    assert_equal "claude", copy["source"]

    assert_equal ClaudeModels::DEFAULT, client.last_kwargs[:model]
    assert_equal({ type: "tool", name: "compose_newsletter" }, client.last_kwargs[:tool_choice])
    assert_equal({ type: "ephemeral" }, client.last_kwargs[:system].first[:cache_control])
    # The per-request timeout the SDK's own 600s default would otherwise win.
    assert client.last_kwargs[:request_options][:timeout].present?
    # The commit body reaches the prompt, so the copy can be about something.
    assert_includes client.last_kwargs[:messages].first[:content], "Why it mattered."
  end

  test "the model's structure is never trusted: junk fields are dropped or bounded" do
    writer, = writer_with(GOOD.merge(
      "subject" => "x" * 400,
      "items" => [
        { "title" => "y" * 300, "body" => "z" * 900 },
        { "title" => "", "body" => "no title" },
        { "title" => 42, "body" => "not a string" },
        "not a hash"
      ] + Array.new(10) { |i| { "title" => "Extra #{i}", "body" => "b" } }
    ))
    copy = writer.call(COMMITS, week: WEEK)

    assert_operator copy["subject"].length, :<=, 140
    assert_equal NewsletterWriter::MAX_ITEMS, copy["items"].size
    assert_operator copy["items"].first["title"].length, :<=, NewsletterWriter::MAX_TITLE_CHARS
    assert_operator copy["items"].first["body"].length, :<=, NewsletterWriter::MAX_BODY_CHARS
    assert_not_includes copy["items"].map { |i| i["title"] }, ""
  end

  test "an unusable reply is nil, not half an edition" do
    writer, = writer_with(GOOD.merge("items" => []))
    assert_nil writer.call(COMMITS, week: WEEK), "no items"

    writer, = writer_with(GOOD.merge("subject" => "  "))
    assert_nil writer.call(COMMITS, week: WEEK), "a blank subject would be refused at freeze"
  end

  test "no key, no commits, or a failed call all return nil" do
    # Blank rather than nil: nil falls through to ENV, which the suite sets,
    # and would put a real HTTP call in the test run.
    keyless = NewsletterWriter.new(api_key: "")
    assert_not keyless.configured?
    assert_nil keyless.call(COMMITS, week: WEEK)

    writer, = writer_with(GOOD)
    assert_nil writer.call([], week: WEEK), "a quiet week costs nothing"

    exploding = NewsletterWriter.new(api_key: "test-key")
    exploding.instance_variable_set(:@client, ExplodingClient.new)
    assert_nil exploding.call(COMMITS, week: WEEK)
  end
end
