require "test_helper"

class SurveyTranslatorCacheTest < ActiveSupport::TestCase
  def setup
    TranslationCache.delete_all
  end

  # Minimal fake Anthropic client that records call count and replays a
  # fixed tool-use response shape per call.
  class FakeClient
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def messages
      self
    end

    def create(model:, max_tokens:, system:, tools:, tool_choice:, messages:)
      @calls += 1
      Struct.new(:content, :usage).new(
        [
          Struct.new(:type, :input).new(:tool_use, {
            cards: [
              { text: "TRANSLATED", description: "", options: [ "A_T", "B_T" ] }
            ]
          })
        ],
        # Mirror the real response shape so usage logging has fields to read.
        Struct.new(:input_tokens, :output_tokens,
                   :cache_creation_input_tokens, :cache_read_input_tokens)
              .new(100, 20, 0, 0)
      )
    end
  end

  test "first call hits the API, second identical call uses cache and skips the API" do
    fake = FakeClient.new
    translator = SurveyTranslator.new(api_key: "x")
    translator.instance_variable_set(:@client, fake)

    card = { "type" => "multiple_choice", "text" => "Hello",
             "description" => "", "options" => [ "A", "B" ] }

    out1 = translator.call(cards: [ card ], target_locale: "es", source_locale: "en")
    assert_equal 1, fake.calls
    assert_equal "TRANSLATED", out1.first["text"]
    assert_equal 1, TranslationCache.count

    # Same source content + same target = cache hit. No new API call.
    out2 = translator.call(cards: [ card ], target_locale: "es", source_locale: "en")
    assert_equal 1, fake.calls, "second call should NOT hit the API"
    assert_equal out1, out2
  end

  test "different target locale is a separate cache entry" do
    fake = FakeClient.new
    translator = SurveyTranslator.new(api_key: "x")
    translator.instance_variable_set(:@client, fake)

    card = { "type" => "multiple_choice", "text" => "Hello",
             "description" => "", "options" => [ "A", "B" ] }

    translator.call(cards: [ card ], target_locale: "es", source_locale: "en")
    translator.call(cards: [ card ], target_locale: "fr", source_locale: "en")

    assert_equal 2, fake.calls
    assert_equal 2, TranslationCache.count
  end

  test "mixed batch only sends cache misses to the API" do
    fake = FakeClient.new
    translator = SurveyTranslator.new(api_key: "x")
    translator.instance_variable_set(:@client, fake)

    cached_card = { "type" => "multiple_choice", "text" => "Hello",
                    "description" => "", "options" => [ "A", "B" ] }
    new_card    = { "type" => "multiple_choice", "text" => "World",
                    "description" => "", "options" => [ "C", "D" ] }

    # Prime the cache with cached_card.
    translator.call(cards: [ cached_card ], target_locale: "es", source_locale: "en")
    assert_equal 1, fake.calls

    # Now mixed: cached_card should come from cache, new_card hits the API.
    out = translator.call(cards: [ cached_card, new_card ], target_locale: "es", source_locale: "en")
    assert_equal 2, fake.calls, "exactly one extra API call for the new card"
    assert_equal 2, out.size
    assert_equal "TRANSLATED", out[0]["text"]
    assert_equal "TRANSLATED", out[1]["text"]
  end
end
