require "test_helper"

class CardTypesTest < ActiveSupport::TestCase
  test "question? excludes welcome_card and token_checkpoint only" do
    refute CardTypes.question?("welcome_card")
    refute CardTypes.question?("token_checkpoint")
    assert CardTypes.question?("multiple_choice")
    assert CardTypes.question?("open_ended")
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
