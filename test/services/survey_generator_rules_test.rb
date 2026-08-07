require "test_helper"

# Guards the "Rules of the Game" values baked into the generator's prompt and
# schema so they can't silently drift from the source rules document (and from
# app/javascript/lib/verto_rules.js, which re-expresses the same values as
# live editor checks).
class SurveyGeneratorRulesTest < ActiveSupport::TestCase
  test "the emit_survey schema targets 12-15 cards including the welcome card" do
    cards = SurveyGenerator::TOOL[:input_schema][:properties][:cards]
    assert_equal 12, cards[:minItems]
    assert_equal 15, cards[:maxItems]
    assert_match "including the single opening welcome_card", cards[:description]
  end

  test "CARD_RULES carries the updated per-type bounds" do
    rules = SurveyGenerator::CARD_RULES
    assert_match "3 or 5",  rules, "image lists are an odd 3 or 5"
    assert_match "5 to 8",  rules, "tap cards carry 5-8 statements"
    assert_match "40 char", rules, "tap statements get a 40-char budget"
    assert_match "4 or 5 options (4 ideal)", rules, "prioritise is 4-5, 4 ideal"
    assert_match "EXACTLY 11 options", rules, "nps is the 0-10 (11-point) scale"
    assert_match(/"0" through\s+"10"/, rules, "nps labels are the plain numerals")
    assert_match "ONE label per point", rules, "rating supplies per-step labels, not just end captions"
  end

  # The label budgets live twice: as numbers in verto_rules' OPTION_LIMITS, and
  # as prose in the prompts the model reads. Nothing links them — a heredoc
  # cannot import a constant — so raising one and forgetting the other fails
  # silently, with the editor permitting 40 while every generated Verto keeps
  # writing to 30. This is the guard on that, and it covers the six services
  # that state the bounds, not just the deck generator: the single-question and
  # flow generators and the three import paths carry their own copies.
  LABEL_BUDGET_PROMPTS = {
    "SurveyGenerator::CARD_RULES"        => -> { SurveyGenerator::CARD_RULES },
    "SurveyGenerator::SYSTEM"            => -> { SurveyGenerator::SYSTEM },
    "SingleQuestionGenerator"            => -> { File.read(Rails.root.join("app/services/single_question_generator.rb")) },
    "FlowGenerator"                      => -> { File.read(Rails.root.join("app/services/flow_generator.rb")) },
    "ManualQuestionImporter"             => -> { File.read(Rails.root.join("app/services/manual_question_importer.rb")) },
    "PdfQuestionImporter"                => -> { File.read(Rails.root.join("app/services/pdf_question_importer.rb")) },
    "QuestionTypeClassifier"             => -> { File.read(Rails.root.join("app/services/question_type_classifier.rb")) }
  }.freeze

  test "no prompt still tells the model a list label is 30 characters" do
    LABEL_BUDGET_PROMPTS.each do |name, source|
      text = source.call
      # Scenario keeps 30 and is a separate question from the list budget, so
      # exempt exactly those lines rather than the whole file.
      offenders = text.lines.each_with_index.select do |line, _|
        line.include?("30 chars") && !line.match?(/scenario|\(2-3,/)
      end

      assert_empty offenders.map { |line, i| "line #{i + 1}: #{line.strip}" },
                   "#{name} still budgets a list label at 30. OPTION_LIMITS says 40 — a prompt " \
                   "left behind means every generated and imported Verto writes to the old rule."
    end
  end

  test "the list budget the prompts state is the one the editor enforces" do
    rules = SurveyGenerator::CARD_RULES

    assert_match(/List types.*40 chars/m, rules, "list types are budgeted at 40")
    assert_match(/prioritise.*40 chars/m, rules, "prioritise shares the list budget")
    assert_match(/Grids.*20 chars/m, rules, "grids stay at 20 — a tile has a column, not a panel")
  end

  test "the SYSTEM prompt scores cards, keeps variety per-type, and drops the scale family" do
    system = SurveyGenerator::SYSTEM
    assert_match "12 to 15 cards TOTAL", system
    assert_no_match(/scale.{0,3}famil/i, system, "range/rating/nps are individual types again")
    assert_match "individual answer types", system
  end
end
