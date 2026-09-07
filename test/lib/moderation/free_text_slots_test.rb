require "test_helper"

# The one definition of "this part of an answer is prose the respondent
# typed", shared by the scrub and the hold. Both directions matter: a missed
# slot is text nobody screened being shown; an over-included one is a birth
# month or a region pick being "moderated".
class ModerationFreeTextSlotsTest < ActiveSupport::TestCase
  CARDS = [
    { "type" => "open_ended", "text" => "Why?" },                                                  # 0
    { "type" => "multiple_choice", "text" => "Pick", "options" => %w[A B], "allow_other" => true }, # 1
    { "type" => "open_ended", "text" => "Born?", "demographic" => true, "input" => "month" },       # 2
    { "type" => "open_ended", "text" => "Where?", "demographic" => true, "input" => "location" },   # 3
    { "type" => "contact_form", "text" => "Stay in touch" },                                       # 4
    { "type" => "rating", "text" => "Score" },                                                     # 5
    { "type" => "open_ended", "text" => "Capital?", "correct" => [ "Paris" ] },                    # 6 graded
    { "type" => "open_ended", "text" => "Anything else?", "demographic" => true }                  # 7 demographic, no input
  ].freeze

  def slots(answers)
    Moderation::FreeTextSlots.each(CARDS, answers).map { |key, slot, text, _card| [ key, slot, text ] }
  end

  test "an open_ended value and any card's Other write-in are free text" do
    found = slots(
      "0" => { "type" => "open_ended", "value" => "because" },
      "1" => { "type" => "multiple_choice", "value" => "A", "other" => "something else" },
      "5" => { "type" => "rating", "value" => 4, "other" => "and a note" }
    )

    assert_equal [ [ "0", "value", "because" ], [ "1", "other", "something else" ], [ "5", "other", "and a note" ] ], found
  end

  test "structured demographic picks and contact forms are not" do
    found = slots(
      "2" => { "type" => "open_ended", "value" => "1999-04" },
      "3" => { "type" => "open_ended", "value" => "GB|Kent|TN1" },
      "4" => { "type" => "contact_form", "value" => { "name" => "Lead", "email" => "l@example.com" }, "other" => "note" }
    )

    assert_empty found
  end

  test "a demographic open_ended without a structured input is still prose" do
    assert_equal [ [ "7", "value", "typed freely" ] ], slots("7" => { "type" => "open_ended", "value" => "typed freely" })
  end

  test "a graded open_ended is yielded — the hold decides about correct answers" do
    assert_equal [ [ "6", "value", "Paris" ] ], slots("6" => { "type" => "open_ended", "value" => "Paris" })
  end

  test "non-strings, blanks and non-hash entries are skipped" do
    found = slots(
      "0" => { "type" => "open_ended", "value" => "   " },
      "1" => { "type" => "multiple_choice", "value" => "A", "other" => nil },
      "5" => { "type" => "rating", "value" => 4 },
      "8" => "not a hash"
    )

    assert_empty found
  end

  test "an index the deck has no card for yields its Other but not its value" do
    found = slots("42" => { "type" => "open_ended", "value" => "orphan", "other" => "typed" })

    assert_equal [ [ "42", "other", "typed" ] ], found
  end

  test "a negative or non-numeric key resolves to no card" do
    assert_nil Moderation::FreeTextSlots.card_at(CARDS, "-1")
    assert_nil Moderation::FreeTextSlots.card_at(CARDS, "abc")
    assert_equal CARDS[1], Moderation::FreeTextSlots.card_at(CARDS, "1")
  end
end
