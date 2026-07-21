require "test_helper"

class QuestionTypeClassifierTest < ActiveSupport::TestCase
  def classifier
    QuestionTypeClassifier.allocate # skip the API-key init; we only call normalize_cards
  end

  test "scenario is classifiable but never freeform-generatable" do
    refute SurveyGenerator::CARD_TYPES.include?("scenario"),
      "scenario must stay out of CARD_TYPES so SurveyGenerator can never invent one"
    refute SurveyGenerator.generatable_types.include?("scenario")
    assert QuestionTypeClassifier::CLASSIFIABLE_TYPES.include?("scenario")
  end

  test "normalize_cards carries scenario pages, assigning stable ids and dropping blanks" do
    cards = [
      { "type" => "scenario", "text" => "Which path?", "pages" => [ "A fork in the trail.", "  ", "You must decide." ], "options" => %w[Left Right] }
    ]
    out = classifier.normalize_cards(cards)

    assert_equal 1, out.size
    card = out.first
    assert_equal "scenario", card["type"]
    assert_equal 2, card["pages"].size, "blank page dropped"
    assert_equal [ "A fork in the trail.", "You must decide." ], card["pages"].map { |p| p["text"] }
    card["pages"].each { |p| assert_match(/\Apg_[0-9a-f]{8}\z/, p["id"]) }
    assert_equal %w[Left Right], card["options"]
  end

  test "normalize_cards bounds scenario pages and page length to the Survey model's caps" do
    long_text = "x" * (Survey::MAX_SCENARIO_PAGE_LENGTH + 50)
    cards = [
      { "type" => "scenario", "text" => "Q", "pages" => Array.new(Survey::MAX_SCENARIO_PAGES + 3) { long_text }, "options" => %w[A B] }
    ]
    card = classifier.normalize_cards(cards).first

    assert_equal Survey::MAX_SCENARIO_PAGES, card["pages"].size
    card["pages"].each { |p| assert_equal Survey::MAX_SCENARIO_PAGE_LENGTH, p["text"].length }
  end

  test "normalize_cards caps scenario options at 3" do
    cards = [
      { "type" => "scenario", "text" => "Q", "pages" => [ "P" ], "options" => %w[A B C D E] }
    ]
    card = classifier.normalize_cards(cards).first
    assert_equal %w[A B C], card["options"]
  end

  test "normalize_cards drops a scenario with no usable pages down to an empty pages array, not an error" do
    cards = [
      { "type" => "scenario", "text" => "Q", "pages" => [], "options" => %w[A B] }
    ]
    card = classifier.normalize_cards(cards).first
    assert_equal "scenario", card["type"]
    assert_equal [], card["pages"]
  end

  test "normalize_cards never emits a scenario for a type outside CLASSIFIABLE_TYPES" do
    cards = [ { "type" => "not_a_real_type", "text" => "Q" } ]
    assert_equal [], classifier.normalize_cards(cards)
  end
end
