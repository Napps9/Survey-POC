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

  # NON_QUESTION_TYPES used to be hand-mirrored into three JS files, and this
  # test compared all three against Ruby. It could not see the FOURTH copy —
  # results_compare_controller's `SKIP_TYPES`, which was the one that had gone
  # stale, because it was spelled differently and lived in a file this list did
  # not name.
  #
  # There is one definition now (app/javascript/lib/question_types.js) and the
  # comparison moved to js_constant_parity_test, which also asserts that nobody
  # re-declares it anywhere. What is left here is the Ruby side of the contract.
  test "the JS mirror is defined in exactly one place" do
    declarations = Dir[Rails.root.join("app/javascript/**/*.js")].select do |path|
      File.read(path).match?(/(?:const|let|var)\s+(?:NON_QUESTION_TYPES|SKIP_TYPES)\s*=\s*(?:new Set\()?\[/)
    end

    assert_equal [ Rails.root.join("app/javascript/lib/question_types.js").to_s ], declarations,
                 "import it from lib/question_types rather than writing the list out again"
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
