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

  test "the optional questions never leak into the auto-appended tail" do
    assert_equal 3, DemographicQuestions.cards.size
    assert_equal 3, DemographicQuestions.append_to([]).size
    assert(DemographicQuestions.append_to([]).none? { |c| c.key?("demographic_key") })
  end
end
