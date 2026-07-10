require "test_helper"

class SurveyTemplatesTest < ActiveSupport::TestCase
  VALID_TYPES = CardTypes.all.map(&:first).to_set

  test "there is a non-empty library of templates" do
    assert_operator SurveyTemplates.all.size, :>=, 3
  end

  test "every template is well-formed and uses canonical card types" do
    ids = SurveyTemplates.all.map { |t| t[:id] }
    assert_equal ids.uniq, ids, "template ids must be unique"

    SurveyTemplates.all.each do |t|
      %i[id name tagline emoji accent theme audience_age key_insight cards].each do |key|
        assert t[key].present?, "#{t[:id]}: missing #{key}"
      end
      assert_match(/\A#[0-9A-Fa-f]{6}\z/, t[:accent], "#{t[:id]}: accent must be a hex colour")

      cards = t[:cards]
      assert cards.first["type"] == "welcome_card", "#{t[:id]}: first card should welcome the respondent"
      assert_operator cards.count { |c| CardTypes.question?(c["type"]) }, :>=, 1,
                      "#{t[:id]}: needs at least one question"

      cards.each do |card|
        assert_includes VALID_TYPES, card["type"], "#{t[:id]}: unknown card type #{card["type"]}"
        assert card["text"].present?, "#{t[:id]}: a card is missing its text"
      end
    end
  end

  test "cards_for returns a deep, mutable copy that does not mutate the registry" do
    cards = SurveyTemplates.cards_for("nps")
    assert cards.first.frozen? == false
    cards.first["text"] = "mutated"
    refute_equal "mutated", SurveyTemplates.find("nps")[:cards].first["text"]
  end

  test "find and cards_for return nil for an unknown id" do
    assert_nil SurveyTemplates.find("nope")
    assert_nil SurveyTemplates.cards_for("nope")
  end
end
