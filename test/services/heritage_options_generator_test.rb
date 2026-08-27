require "test_helper"
require "ostruct"

# The five country heritages that replace the global taxonomy on a tailored
# Heritage card. The contract under test is the failure side: this content is
# read by respondents describing their own ethnicity, so every abnormal
# response has to come back as nil — a MISSING verdict the caller turns into
# the global nine — rather than as a partial or invented list.
class HeritageOptionsGeneratorTest < ActiveSupport::TestCase
  # Replays one canned tool_use response (or raises), recording the create
  # kwargs so tests can assert what was actually sent.
  class ScriptedClient
    attr_reader :last_kwargs, :calls

    def initialize(input: nil, error: nil)
      @input = input
      @error = error
      @calls = 0
    end

    def messages = self

    def create(**kwargs)
      @calls += 1
      @last_kwargs = kwargs
      raise @error if @error

      OpenStruct.new(
        content: @content || [ OpenStruct.new(type: "tool_use", input: @input) ],
        usage: OpenStruct.new(input_tokens: 10, output_tokens: 5,
                              cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end

    # The forced tool call never happened — what a max_tokens truncation or a
    # refusal stop looks like.
    def self.without_tool_block(text: "I cannot help with that")
      new.tap { |c| c.instance_variable_set(:@content, [ OpenStruct.new(type: "text", text: text) ]) }
    end
  end

  def generator_with(client)
    gen = HeritageOptionsGenerator.new(api_key: "test")
    gen.instance_variable_set(:@client, client)
    gen
  end

  FIVE = [ "White British", "Indian", "Pakistani", "Black Caribbean", "Chinese" ].freeze

  # ── The happy path ────────────────────────────────────────────────────────

  test "returns the model's list verbatim — sanitising is the caller's job" do
    gen = generator_with(ScriptedClient.new(input: { "heritages" => FIVE }))
    assert_equal FIVE, gen.call(country: "GB")
  end

  test "forces the tool call and names the country, not its code" do
    client = ScriptedClient.new(input: { "heritages" => FIVE })
    generator_with(client).call(country: "GB")

    kwargs = client.last_kwargs
    assert_equal({ type: "tool", name: "emit_heritages" }, kwargs[:tool_choice])
    assert_equal ClaudeModels::FAST, kwargs[:model]

    content = kwargs[:messages].first[:content]
    assert_match "United Kingdom", content,
                 "the model gets the country's name — an alpha-2 code is ambiguous"
    # An English Verto used to get NO language instruction at all — every
    # generator opened `return "" if locale == SupportedLocales::DEFAULT`. That
    # silence is what let the model inherit the dialect of the prompts, which
    # are British throughout, and hand a US creator's questions back respelled.
    # English is stated now, and which English.
    assert_match(/LANGUAGE: Write every label in British English/, content)
    refute_match(/Do not use English/, content,
                 "nonsense for an English variant — a self-contradicting instruction " \
                 "makes output unpredictable rather than merely wrong")
  end

  test "asks for the labels in the Verto's language rather than translating after" do
    client = ScriptedClient.new(input: { "heritages" => FIVE })
    generator_with(client).call(country: "GB", locale: "fr")

    content = client.last_kwargs[:messages].first[:content]
    assert_match(/LANGUAGE: Write every label in French/, content)
  end

  # ── The failure contract: every one of these is nil, never a partial list ──

  test "an empty list is a real answer — the country has no accepted set" do
    # France restricts ethnic statistics; Antarctica has no resident
    # population. The prompt asks for [] there rather than an invention, and
    # nil sends the caller to the global taxonomy.
    gen = generator_with(ScriptedClient.new(input: { "heritages" => [] }))
    assert_equal [], gen.call(country: "FR"),
                 "the empty list reaches the caller intact; HeritageOptions turns it into the fallback"
  end

  test "a response with no tool block is a failed verdict" do
    gen = generator_with(ScriptedClient.without_tool_block)
    assert_nil gen.call(country: "GB")
  end

  test "a tool input missing the key is a failed verdict" do
    gen = generator_with(ScriptedClient.new(input: { "something_else" => FIVE }))
    assert_nil gen.call(country: "GB")
  end

  test "an API error never propagates to the creator" do
    gen = generator_with(ScriptedClient.new(error: RuntimeError.new("overloaded")))
    assert_nil gen.call(country: "GB")
  end

  test "an unknown country never reaches the API" do
    client = ScriptedClient.new(input: { "heritages" => FIVE })
    assert_nil generator_with(client).call(country: "ZZ")
    assert_equal 0, client.calls, "a code WorldRegions doesn't know is not worth a paid call"
  end

  # ── The prompt itself ─────────────────────────────────────────────────────

  test "the prompt anchors on official categories and forbids the tail options" do
    system = HeritageOptionsGenerator::SYSTEM
    assert_match(/census/i, system, "official categories are the source of truth")
    assert_match(/self-identif/i, system)
    assert_match(/slur/i, system, "the terminology floor has to be explicit")
    assert_match(/EMPTY list/, system, "the no-accepted-set escape is what stops inventions")
    assert_match(/Prefer not to say/, system, "the card appends its own; a duplicate wastes a slot")
  end

  test "the tool schema bounds the list without forcing one" do
    schema = HeritageOptionsGenerator::TOOL[:input_schema][:properties][:heritages]
    assert_equal HeritageOptionsGenerator::WANTED, schema[:maxItems]
    assert_nil schema[:minItems],
               "a minimum would force an invention for exactly the countries where inventing is worst"
  end
end
