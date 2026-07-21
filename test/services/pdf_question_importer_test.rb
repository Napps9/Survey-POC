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

  test "trims tap_card options to the 8-statement cap" do
    importer = importer_returning(
      "title" => "T",
      "cards" => [
        { "type" => "tap_card", "text" => "React to remote work", "options" => %w[a b c d e f g h i j] },
        { "type" => "tap_card", "text" => "React to office work", "options" => %w[a b c d e] }
      ]
    )

    result = importer.call(pdf_data: "x")

    assert_equal %w[a b c d e f g h], result["cards"][0]["options"], "over the cap trims to the first 8"
    assert_equal %w[a b c d e], result["cards"][1]["options"], "within the 5-8 band untouched"
  end

  test "returns no cards when the model emits none" do
    importer = importer_returning("title" => "Empty", "cards" => [])

    result = importer.call(pdf_data: "x")

    assert_equal [], result["cards"]
  end

  # Regression: normalize_cards used to silently drop original_text/compliant/
  # issue, which made SurveysController#import_pdf's `flagged = cards.select
  # { |c| c["compliant"] == false }` check always empty in production — the
  # verbatim-vs-optimised review screen was unreachable no matter what Claude
  # judged. These three fields must survive the real #call pipeline.
  test "preserves original_text/compliant/issue through the real pipeline" do
    importer = importer_returning(
      "title" => "T",
      "cards" => [
        { "type" => "multiple_choice", "text" => "Which one?", "original_text" => "Which one do you prefer out of these options?",
          "compliant" => false, "issue" => "Over the 100-character cap", "options" => %w[A B C] },
        { "type" => "yes_no", "text" => "Did you attend?", "original_text" => "Did you attend?", "compliant" => true, "issue" => "" }
      ]
    )

    result = importer.call(pdf_data: "x")

    flagged = result["cards"].select { |c| c["compliant"] == false }
    assert_equal 1, flagged.size, "the review screen's flagging check must see a real false, not a stripped nil"
    assert_equal "Which one do you prefer out of these options?", flagged.first["original_text"]
    assert_equal "Over the 100-character cap", flagged.first["issue"]

    compliant_card = result["cards"].find { |c| c["type"] == "yes_no" }
    assert_equal true, compliant_card["compliant"]
    assert_equal "Did you attend?", compliant_card["original_text"]
  end

  test "a long narrative question with a short closing question is imported as scenario, not truncated" do
    importer = importer_returning(
      "title" => "T",
      "cards" => [
        { "type" => "scenario", "text" => "Which would you choose?", "original_text" => "Which would you choose?",
          "compliant" => true,
          "pages" => [ "Summers are getting hotter and your room is stuffy at night.", "You could run the air conditioner, but it costs more." ],
          "options" => [ "Windows and fans", "Air conditioner" ] }
      ]
    )

    result = importer.call(pdf_data: "x")
    card = result["cards"].first

    assert_equal "scenario", card["type"]
    assert_equal 2, card["pages"].size
    assert_equal true, card["compliant"], "a scenario's short closing text is inherently rule-compliant"
    assert_equal "Which would you choose?", card["original_text"]
  end
end
