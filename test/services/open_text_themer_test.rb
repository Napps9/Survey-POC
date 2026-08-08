require "test_helper"
require "ostruct"

# Which answers the themes are actually derived from.
#
# This used to be the first 250 answers in import order — not a sample, a head
# slice. On a 27,088-answer column that is 0.9% of it, and on a paper file the
# first rows are whichever school happened to be transcribed first, so the
# "themes for this question" were the themes for that school. The counts were
# then handed to Ask Verto alongside a response count taken over a different
# denominator, with nothing marking the difference.
class OpenTextThemerTest < ActiveSupport::TestCase
  # Records every batch it is shown, and returns one theme per call plus the
  # first answer of the batch as a quote, so the merge is observable.
  class RecordingClient
    attr_reader :batches

    def initialize = @batches = []

    def messages = self

    def create(**kwargs)
      body = kwargs[:messages].first[:content]
      indexed = body.scan(/^\[\d+\] (.*)$/).flatten
      @batches << indexed

      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", name: "emit_themes", input: {
          themes: [ { label: "Cost", count: indexed.size } ],
          quotes: [ { index: 0, theme: "Cost" } ]
        }) ],
        usage: OpenStruct.new(input_tokens: 1, output_tokens: 1,
                              cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end
  end

  def themer_with(client)
    themer = OpenTextThemer.new(api_key: "test")
    themer.instance_variable_set(:@client, client)
    themer
  end

  def answers(n) = Array.new(n) { |i| "Answer number #{i} about the cost of things" }

  test "every answer is read, not the first 250" do
    client = RecordingClient.new
    result = themer_with(client).call(question_text: "Why?", texts: answers(600))

    assert_equal 3, client.batches.size, "600 answers is three batches of 250"
    assert_equal 600, client.batches.sum(&:size)
    assert_equal 600, result[:read]
    assert_equal 600, result[:of]
    assert_not result[:sampled]
  end

  test "theme counts from every batch are merged, not just the first" do
    result = themer_with(RecordingClient.new).call(question_text: "Why?", texts: answers(600))
    cost = result[:themes].find { |t| t["label"] == "Cost" }

    assert_equal 600, cost["count"],
      "a theme covering every batch must count every batch — one batch's number would read as the column's"
  end

  test "quotes are drawn from across the column, not off the top" do
    result = themer_with(RecordingClient.new).call(question_text: "Why?", texts: answers(600))
    bodies = result[:quotes].map { |q| q[:body] }

    assert_equal 3, bodies.size
    assert_includes bodies, "Answer number 0 about the cost of things"
    assert_includes bodies, "Answer number 250 about the cost of things"
    assert_includes bodies, "Answer number 500 about the cost of things"
  end

  test "a column too large to read whole is sampled evenly and says so" do
    # The ceiling exists so one enormous column cannot run away with the
    # indexing budget. When it bites, the batches must still be spread across
    # the whole column — a truncated head slice is exactly the bug being fixed.
    client = RecordingClient.new
    result = nil
    with_env("ASK_VERTO_MAX_THEME_BATCHES" => "4") do
      result = themer_with(client).call(question_text: "Why?", texts: answers(5_000))
    end

    assert_equal 4, client.batches.size
    assert result[:sampled], "a sampled result has to admit it"
    assert_equal 5_000, result[:of]
    assert_equal 1_000, result[:read]

    firsts = client.batches.map(&:first)
    assert_equal firsts, firsts.uniq, "four copies of the same batch is not a spread"
    assert_includes firsts.last, "Answer number 3750", "the tail of the column must be represented"
  end

  test "a question with too few answers is not themed at all" do
    client = RecordingClient.new
    result = nil
    CorpusEntry.with_min_sample_size(30) do
      result = themer_with(client).call(question_text: "Why?", texts: answers(29))
    end

    assert_empty client.batches, "no call should have been made"
    assert_empty result[:themes]
    assert_equal 29, result[:of]
    assert_equal 0, result[:read]
  end

  private

  # MAX_BATCHES is read from the environment at load, so the constant is what
  # has to move for the test — reloading the class would be worse.
  def with_env(values)
    previous = OpenTextThemer::MAX_BATCHES
    OpenTextThemer.send(:remove_const, :MAX_BATCHES)
    OpenTextThemer.const_set(:MAX_BATCHES, values["ASK_VERTO_MAX_THEME_BATCHES"].to_i)
    yield
  ensure
    OpenTextThemer.send(:remove_const, :MAX_BATCHES)
    OpenTextThemer.const_set(:MAX_BATCHES, previous)
  end
end
