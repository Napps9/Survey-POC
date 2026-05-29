require "test_helper"
require "ostruct"

class PdfQuestionImporterTest < ActiveSupport::TestCase
  # Builds an importer with a fake Anthropic client that returns a canned
  # tool_use block, so we can exercise call/normalisation without the API.
  def importer_returning(input)
    importer = PdfQuestionImporter.allocate
    block    = OpenStruct.new(type: "tool_use", input: input)
    response = OpenStruct.new(content: [ block ])
    messages = Object.new
    messages.define_singleton_method(:create) { |**_| response }
    client = OpenStruct.new(messages: messages)
    importer.instance_variable_set(:@client, client)
    importer
  end

  test "keeps well-formed cards and preserves their options" do
    importer = importer_returning(
      "title" => "Volunteer check-in",
      "cards" => [
        { "type" => "select_one_grid", "text" => "Which best describes you?", "options" => %w[New Returning Lapsed Curious] },
        { "type" => "open_ended", "text" => "What would make you stay?" }
      ]
    )

    result = importer.call(pdf_data: "base64data")

    assert_equal "Volunteer check-in", result["title"]
    assert_equal 2, result["cards"].size
    assert_equal %w[New Returning Lapsed Curious], result["cards"][0]["options"]
  end

  test "drops cards with an unknown type or blank text" do
    importer = importer_returning(
      "title" => "T",
      "cards" => [
        { "type" => "matrix",          "text" => "Unsupported type" },   # not a real type
        { "type" => "multiple_choice", "text" => "   " },                # blank text
        { "type" => "rating",          "text" => "Rate the venue", "options" => %w[1 2 3 4 5] }
      ]
    )

    result = importer.call(pdf_data: "x")

    assert_equal 1, result["cards"].size
    assert_equal "rating", result["cards"][0]["type"]
  end

  test "strips options from types that never carry them" do
    importer = importer_returning(
      "title" => "T",
      "cards" => [
        { "type" => "open_ended", "text" => "Tell us more", "options" => %w[should be dropped] },
        { "type" => "yes_no",     "text" => "Did you attend?", "options" => %w[Yes No] }
      ]
    )

    result = importer.call(pdf_data: "x")

    assert_not result["cards"][0].key?("options"), "open_ended keeps no options"
    assert_not result["cards"][1].key?("options"), "yes_no keeps no explicit options"
  end

  test "trims tap_card options to exactly three" do
    importer = importer_returning(
      "title" => "T",
      "cards" => [
        { "type" => "tap_card", "text" => "React to remote work", "options" => %w[a b c d e] }
      ]
    )

    result = importer.call(pdf_data: "x")

    assert_equal %w[a b c], result["cards"][0]["options"]
  end

  test "returns no cards when the model emits none" do
    importer = importer_returning("title" => "Empty", "cards" => [])

    result = importer.call(pdf_data: "x")

    assert_equal [], result["cards"]
  end
end
