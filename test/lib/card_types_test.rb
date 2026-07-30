require "test_helper"

class CardTypesTest < ActiveSupport::TestCase
  test "question? excludes the non-answer screens only" do
    refute CardTypes.question?("welcome_card")
    refute CardTypes.question?("token_checkpoint")
    refute CardTypes.question?("consent_gate")
    assert CardTypes.question?("multiple_choice")
    assert CardTypes.question?("open_ended")
    assert CardTypes.question?("scenario")
  end

  # NON_QUESTION_TYPES is hand-mirrored into three JS files (progress counting,
  # the type panel, and the Rules-of-the-Game scorer). A type added on one side
  # and not the other gets counted as a question in some places and not others,
  # which is invisible until a score or a progress count looks wrong — so the
  # lists are compared directly.
  test "the JavaScript mirrors of NON_QUESTION_TYPES match Ruby" do
    mirrors = {
      "app/javascript/controllers/type_panel_controller.js" => nil,
      "app/javascript/controllers/survey_editor_controller.js" => nil,
      "app/javascript/lib/verto_rules.js" => nil
    }

    mirrors.each_key do |path|
      source = Rails.root.join(path).read
      line = source[/^const NON_QUESTION_TYPES = \[(.*?)\]/m, 1]
      assert line, "#{path}: no NON_QUESTION_TYPES declaration found"
      assert_equal CardTypes::NON_QUESTION_TYPES, line.scan(/"([^"]+)"/).flatten,
                   "#{path} is out of step with CardTypes::NON_QUESTION_TYPES"
    end
  end

  test "consent_gate is offered in the picker" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ], cards: [])
    assert CardTypes.pickable_for(s).any? { |key, _attrs| key == "consent_gate" }
  end

  test "pickable_for hides token_checkpoint unless the Verto is tokenised" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    plain = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    tokenised = org.surveys.create!(title: "T2", theme: "T", audience_age: "all", key_insight: "x",
                                     default_locale: "en", locales: [ "en" ], cards: [],
                                     tokenisation_enabled: true)

    refute CardTypes.pickable_for(plain).any? { |key, _attrs| key == "token_checkpoint" }
    assert CardTypes.pickable_for(tokenised).any? { |key, _attrs| key == "token_checkpoint" }
    refute CardTypes.pickable_for(nil).any? { |key, _attrs| key == "token_checkpoint" }
  end
end
