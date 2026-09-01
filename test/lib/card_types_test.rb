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

  test "pickable_for hides token_checkpoint and points_intro unless the Verto is tokenised" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    plain = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                                 default_locale: "en", locales: [ "en" ], cards: [])
    tokenised = org.surveys.create!(title: "T2", theme: "T", audience_age: "all", key_insight: "x",
                                     default_locale: "en", locales: [ "en" ], cards: [],
                                     tokenisation_enabled: true)

    %w[token_checkpoint points_intro].each do |type|
      refute CardTypes.pickable_for(plain).any? { |key, _attrs| key == type }, "#{type} offered untokenised"
      assert CardTypes.pickable_for(tokenised).any? { |key, _attrs| key == type }, "#{type} missing tokenised"
      refute CardTypes.pickable_for(nil).any? { |key, _attrs| key == type }, "#{type} offered with no survey"
    end
  end

  test "pickable_for offers points_intro only while the deck has none" do
    org = Organisation.create!(name: "O", slug: "o-#{SecureRandom.hex(3)}")
    s = org.surveys.create!(title: "T", theme: "T", audience_age: "all", key_insight: "x",
                            default_locale: "en", locales: [ "en" ],
                            tokenisation_enabled: true,
                            cards: [ { "type" => "points_intro", "cid" => "pi" } ])

    refute CardTypes.pickable_for(s).any? { |key, _attrs| key == "points_intro" },
           "a second points_intro cannot survive the save (enforce_single_points_intro), " \
           "so offering it is offering a card that cannot survive"
  end

  # ── badge/panel_label: i18n-aware, YAML-value default (2.7) ────────────────

  test "badge/panel_label pick up the given locale, falling back to the YAML default" do
    assert_equal "RANGE", CardTypes.badge("range", locale: :en)
    assert_equal "ÉCHELLE", CardTypes.badge("range", locale: :fr)
    assert_equal "DRAG THE SLIDER", CardTypes.panel_label("range", locale: :en)
    assert_equal "FAITES GLISSER LE CURSEUR", CardTypes.panel_label("range", locale: :fr)
  end

  test "badge/panel_label default to the ambient I18n.locale when none is given" do
    I18n.with_locale(:fr) do
      assert_equal "ÉCHELLE", CardTypes.badge("range")
      assert_equal "FAITES GLISSER LE CURSEUR", CardTypes.panel_label("range")
    end
  end

  test "badge/panel_label degrade to blank for an unknown type, same as meta()" do
    assert_equal "", CardTypes.badge("not_a_real_type")
    assert_equal "", CardTypes.panel_label("not_a_real_type")
  end

  # Every type with a non-blank badge/panel_label in config/card_types.yml
  # must have a matching en.yml entry that mirrors it exactly. Without this a
  # new type (or a retext of an existing one) silently keeps working — the
  # YAML default still renders — right up until a translation exists for any
  # OTHER locale and this one alone is left showing stale/absent English.
  test "en.yml's card.badge/panel_label mirror config/card_types.yml exactly" do
    problems = []
    CardTypes.all.each do |key, attrs|
      if attrs["badge"].to_s.present?
        en = I18n.t("card.badge.#{key}", locale: :en, default: nil)
        problems << "card.badge.#{key} missing from en.yml" if en.nil?
        problems << "card.badge.#{key} (#{en.inspect}) has drifted from card_types.yml (#{attrs['badge'].inspect})" if en && en != attrs["badge"]
      end
      if attrs["panel_label"].to_s.present?
        en = I18n.t("card.panel_label.#{key}", locale: :en, default: nil)
        problems << "card.panel_label.#{key} missing from en.yml" if en.nil?
        problems << "card.panel_label.#{key} (#{en.inspect}) has drifted from card_types.yml (#{attrs['panel_label'].inspect})" if en && en != attrs["panel_label"]
      end
    end
    assert_empty problems, problems.join("\n")
  end
end
