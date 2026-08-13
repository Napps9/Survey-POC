require "test_helper"

class DemographicQuestionsTest < ActiveSupport::TestCase
  test "the birth-date card uses the month+year-only picker, not free text" do
    card = DemographicQuestions.cards.find { |c| c["text"] == "When were you born?" }
    assert_equal "month", card["input"]
    assert card["demographic"]
  end

  test "append_to adds the demographic tail once and never duplicates it" do
    cards = [ { "type" => "welcome_card", "text" => "Welcome" } ]
    once  = DemographicQuestions.append_to(cards)
    assert_equal 4, once.size

    twice = DemographicQuestions.append_to(once)
    assert_equal once, twice
  end

  # ── Opt-in questions (OPTIONAL_CARDS) ───────────────────────────────────────

  test "optional_card returns a keyed, flagged card and nil for unknown keys" do
    card = DemographicQuestions.optional_card("heritage")

    assert card["demographic"]
    assert_equal "heritage", card["demographic_key"]
    assert_equal "multiple_choice", card["type"]
    assert_equal 9, card["options"].size
    assert_nil DemographicQuestions.optional_card("astrology")
  end

  test "optional_card resolves a locale and falls back to English" do
    fr = DemographicQuestions.optional_card("neurodiversity", locale: "fr")
    en = DemographicQuestions.optional_card("neurodiversity")

    refute_equal en["text"], fr["text"], "the French Verto must ask in French"
    assert_equal 9, fr["options"].size
    assert_equal en, DemographicQuestions.optional_card("neurodiversity", locale: "xx-nope")
  end

  test "a wrong-length translated options list is refused — answers are positional" do
    I18n.backend.store_translations(:en, demographics: { optional: { heritage: { options: %w[a b] } } })
    card = DemographicQuestions.optional_card("heritage")

    assert_equal DemographicQuestions::OPTIONAL_CARDS["heritage"]["options"].size, card["options"].size
  ensure
    I18n.backend.reload!
  end

  test "optional_card deep-dups — callers can mutate without corrupting the registry" do
    card = DemographicQuestions.optional_card("heritage")
    card["options"] << "tampered"
    card["cid"] = "c_x"

    assert_equal 9, DemographicQuestions.optional_card("heritage")["options"].size
    refute DemographicQuestions::OPTIONAL_CARDS["heritage"].key?("cid")
  end

  test "neuro_exclusive_labels carries the exclusive pair across locales" do
    labels = DemographicQuestions.neuro_exclusive_labels

    assert_includes labels, "None of these"
    assert_includes labels, "Prefer not to say"
    assert_includes labels, "Aucune de ces réponses", "French exclusives must be recognised too"
    refute_includes labels, "ADHD", "a real condition must never be treated as exclusive"
  end

  # ── The country-tailored heritage card ────────────────────────────────────

  test "heritage_tail_options is the registry's own escape-hatch pair, per locale" do
    assert_equal [ "Another heritage", "Prefer not to say" ],
                 DemographicQuestions.heritage_tail_options
    assert_equal DemographicQuestions.optional_card("heritage", locale: "fr")["options"].last(2),
                 DemographicQuestions.heritage_tail_options(locale: "fr")
  end

  test "country_heritage_card swaps the taxonomy but keeps the escape hatches" do
    five = [ "White British", "Indian", "Pakistani", "Black Caribbean", "Chinese" ]
    card = DemographicQuestions.country_heritage_card(country: "gb", five: five)

    assert_equal five + DemographicQuestions.heritage_tail_options, card["options"]
    assert_equal 7, card["options"].size
    assert card["allow_other"], "five categories will miss people"
    assert_equal "GB", card["heritage_country"], "the code is normalised, not echoed"
    assert_equal "heritage", card["demographic_key"], "it is still the same question"
    assert card["demographic"]
  end

  test "a French Verto's tailored card carries the French question and tail" do
    card = DemographicQuestions.country_heritage_card(
      country: "FR", five: %w[un deux trois quatre cinq], locale: "fr"
    )

    assert_equal DemographicQuestions.optional_card("heritage", locale: "fr")["text"], card["text"]
    assert_equal DemographicQuestions.heritage_tail_options(locale: "fr"), card["options"].last(2)
  end

  test "no usable list means the plain registry card, never a half-tailored one" do
    [ nil, [] ].each do |five|
      card = DemographicQuestions.country_heritage_card(country: "GB", five: five)
      assert_equal 9, card["options"].size
      assert_nil card["heritage_country"], "a fallback must not claim a tailoring it didn't get"
    end

    unknown = DemographicQuestions.country_heritage_card(country: "ZZ", five: %w[a b c d e])
    assert_equal 9, unknown["options"].size
    assert_nil unknown["heritage_country"]
  end

  test "building a tailored card never corrupts the frozen registry" do
    DemographicQuestions.country_heritage_card(country: "GB", five: %w[a b c d e])

    assert_equal 9, DemographicQuestions::OPTIONAL_CARDS["heritage"]["options"].size
    refute DemographicQuestions::OPTIONAL_CARDS["heritage"].key?("allow_other")
    refute DemographicQuestions::OPTIONAL_CARDS["heritage"].key?("heritage_country")
  end

  test "the optional questions never leak into the auto-appended tail" do
    assert_equal 3, DemographicQuestions.cards.size
    assert_equal 3, DemographicQuestions.append_to([]).size
    assert(DemographicQuestions.append_to([]).none? { |c| c.key?("demographic_key") })
  end
end
