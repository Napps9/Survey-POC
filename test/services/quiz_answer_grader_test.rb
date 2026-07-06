require "test_helper"
require "ostruct"

class QuizAnswerGraderTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :last_kwargs
    def initialize(correct:)
      @correct = correct
    end
    def messages = self
    def create(**kwargs)
      @last_kwargs = kwargs
      OpenStruct.new(
        content: [ OpenStruct.new(type: "tool_use", input: { "correct" => @correct }) ],
        usage: OpenStruct.new(input_tokens: 40, output_tokens: 5, cache_creation_input_tokens: 0, cache_read_input_tokens: 0)
      )
    end
  end

  def grader_with(client)
    g = QuizAnswerGrader.allocate
    g.instance_variable_set(:@client, client)
    g
  end

  test "returns true when the model judges the answer a semantic match" do
    grader = grader_with(FakeClient.new(correct: true))
    assert grader.call(question: "Name one power that the UK Parliament has.",
                        accepted_answers: [ "make laws", "pass laws", "set taxes" ],
                        answer: "make the laws")
  end

  test "returns false when the model judges the answer wrong" do
    grader = grader_with(FakeClient.new(correct: false))
    refute grader.call(question: "Name one power that the UK Parliament has.",
                        accepted_answers: [ "make laws" ],
                        answer: "bake a cake")
  end

  test "uses the FAST model and sends the question, accepted answers and respondent answer" do
    client = FakeClient.new(correct: true)
    grader_with(client).call(question: "Q?", accepted_answers: [ "A", "B" ], answer: "my answer")
    assert_equal ClaudeModels::FAST, client.last_kwargs[:model]
    msg = client.last_kwargs[:messages].first[:content]
    assert_match "Q?", msg
    assert_match "A | B", msg
    assert_match "my answer", msg
  end

  test "returns false without calling the API for a blank question, answer, or accepted list" do
    client = Object.new # would raise NoMethodError if ever called
    grader = grader_with(client)
    refute grader.call(question: "", accepted_answers: [ "x" ], answer: "y")
    refute grader.call(question: "Q", accepted_answers: [], answer: "y")
    refute grader.call(question: "Q", accepted_answers: [ "x" ], answer: "  ")
  end

  test "returns false and never raises when the client errors" do
    boom = Object.new
    boom.define_singleton_method(:messages) { boom }
    boom.define_singleton_method(:create) { |**_kw| raise "network down" }
    grader = grader_with(boom)
    refute grader.call(question: "Q", accepted_answers: [ "x" ], answer: "y")
  end
end
