require "test_helper"

# The re-keying is the whole risk of the withdrawal. Answers are keyed by card
# index, so an off-by-one here doesn't raise or look wrong — it silently files
# every answer after the removed card under the wrong question, and the results
# screen renders that mistake as clean data. These tests are the only thing that
# can catch it, so they assert positions, not just counts.
class LegacyCardPurgeTest < ActiveSupport::TestCase
  def build_survey(cards:, **attrs)
    org = Organisation.create!(name: "Purge Org", slug: "st-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "S", theme: "T", audience_age: "all", key_insight: "x",
                        default_locale: "en", locales: [ "en" ], cards: cards, **attrs)
  end

  def card(type, cid, extra = {})
    { "type" => type, "cid" => cid, "text" => "#{type} #{cid}" }.merge(extra)
  end

  def contact_card(cid = "c_contact")
    card("contact_form", cid)
  end

  def neuro_card(cid = "c_neuro")
    card("select_many", cid, "demographic" => true, "demographic_key" => "neurodiversity",
                             "options" => [ "ADHD", "Autism" ])
  end

  def answer(value)
    { "value" => value }
  end

  def add_response!(survey, answers)
    survey.responses.create!(session_token: SecureRandom.hex(8), status: "completed",
                             answers: answers)
  end

  # ── doomed? ────────────────────────────────────────────────────────────────

  test "matches the two withdrawn kinds and nothing else" do
    assert LegacyCardPurge.doomed?(contact_card)
    assert LegacyCardPurge.doomed?(neuro_card)

    refute LegacyCardPurge.doomed?(card("open_ended", "c_1"))
    refute LegacyCardPurge.doomed?(card("select_many", "c_2", "demographic" => true,
                                                              "demographic_key" => "heritage"))
    refute LegacyCardPurge.doomed?(card("select_many", "c_3", "demographic" => true))
    refute LegacyCardPurge.doomed?(nil)
    refute LegacyCardPurge.doomed?("not a card")
  end

  # ── the core case ──────────────────────────────────────────────────────────

  test "removing cards mid-deck moves every later answer down to match" do
    survey = build_survey(cards: [
      card("welcome_card", "c_w"), card("rating", "c_q1"), contact_card,
      card("nps", "c_q2"), neuro_card, card("open_ended", "c_q3")
    ])
    resp = add_response!(survey, {
      "0" => answer("welcome"), "1" => answer(4), "2" => answer({ "name" => "Ada" }),
      "3" => answer(9), "4" => answer([ "ADHD" ]), "5" => answer("free text")
    })

    assert_equal 2, LegacyCardPurge.purge_survey!(survey)

    assert_equal %w[ c_w c_q1 c_q2 c_q3 ], survey.reload.cards.map { |c| c["cid"] }
    # Each surviving answer still sits under the card it was given for.
    assert_equal({ "0" => answer("welcome"), "1" => answer(4),
                   "2" => answer(9), "3" => answer("free text") }, resp.reload.answers)
  end

  test "two removals before one card shift it down by two" do
    survey = build_survey(cards: [
      card("rating", "c_a"), contact_card("c_c1"), neuro_card("c_n1"),
      card("nps", "c_b"), card("open_ended", "c_d")
    ])
    resp = add_response!(survey, {
      "0" => answer(1), "1" => answer({}), "2" => answer([]), "3" => answer(7), "4" => answer("x")
    })

    LegacyCardPurge.purge_survey!(survey)

    assert_equal({ "0" => answer(1), "1" => answer(7), "2" => answer("x") }, resp.reload.answers)
  end

  test "a partially answered response keeps its gaps in the right places" do
    survey = build_survey(cards: [
      card("rating", "c_a"), contact_card, card("nps", "c_b"), card("open_ended", "c_c")
    ])
    resp = add_response!(survey, { "0" => answer(3), "3" => answer("only the last one") })

    LegacyCardPurge.purge_survey!(survey)

    assert_equal({ "0" => answer(3), "2" => answer("only the last one") }, resp.reload.answers)
  end

  test "non-index keys pass through and out-of-range keys still shift" do
    survey = build_survey(cards: [ contact_card, card("rating", "c_a") ])
    resp = add_response!(survey, { "0" => answer({}), "1" => answer(2), "notes" => answer("hi") })

    LegacyCardPurge.purge_survey!(survey)

    assert_equal({ "0" => answer(2), "notes" => answer("hi") }, resp.reload.answers)
  end

  # ── answered ───────────────────────────────────────────────────────────────

  test "a response whose only answer was a withdrawn card stops being a responder" do
    survey = build_survey(cards: [ card("rating", "c_a"), contact_card ])
    only_contact = add_response!(survey, { "1" => answer({ "name" => "Ada" }) })
    also_real    = add_response!(survey, { "0" => answer(5), "1" => answer({ "name" => "Bo" }) })

    assert only_contact.reload.answered, "fixture should start as a responder"

    LegacyCardPurge.purge_survey!(survey)

    refute only_contact.reload.answered
    assert also_real.reload.answered
  end

  # ── dangling targets ───────────────────────────────────────────────────────

  test "branching that pointed at a withdrawn card is cleared, end targets are not" do
    router = card("multiple_choice", "c_r", "logic" => {
      "routes" => [
        { "match" => { "op" => "equals", "value" => "A" }, "to" => { "card" => "c_contact" } },
        { "match" => { "op" => "equals", "value" => "B" }, "to" => { "end" => "hub" } }
      ],
      "default" => { "card" => "c_contact" }
    })
    trailing = card("rating", "c_t", "next" => { "card" => "c_neuro" })
    survey = build_survey(
      cards: [ router, contact_card, neuro_card, trailing ],
      flows: [ { "id" => "f1", "name" => "F", "exit" => { "card" => "c_contact" } },
               { "id" => "f2", "name" => "G", "exit" => { "end" => "done" } } ],
      token_intro_cid: "c_neuro"
    )

    LegacyCardPurge.purge_survey!(survey)
    survey.reload

    logic = survey.cards.first["logic"]
    assert_equal [ { "end" => "hub" } ], logic["routes"].map { |r| r["to"] }
    refute logic.key?("default")
    refute survey.cards.last.key?("next")
    refute survey.flows.first.key?("exit")
    assert_equal({ "end" => "done" }, survey.flows.last["exit"])
    assert_nil survey.token_intro_cid
  end

  test "logic left with nothing to say is removed entirely" do
    router = card("yes_no", "c_r", "logic" => {
      "routes" => [ { "match" => { "op" => "equals", "value" => "Yes" },
                      "to" => { "card" => "c_contact" } } ]
    })
    survey = build_survey(cards: [ router, contact_card ])

    LegacyCardPurge.purge_survey!(survey)

    refute survey.reload.cards.first.key?("logic")
  end

  # ── the undo bin ───────────────────────────────────────────────────────────

  test "the undo bin gives up its withdrawn cards and keeps the rest" do
    survey = build_survey(
      cards: [ card("rating", "c_a"), contact_card ],
      deleted_cards: [ { "card" => contact_card("c_binned"), "deleted_at" => "2026-08-01T00:00:00Z" },
                       { "card" => card("range", "c_keep"), "deleted_at" => "2026-08-01T00:00:00Z" } ]
    )

    LegacyCardPurge.purge_survey!(survey)

    assert_equal [ "c_keep" ], survey.reload.deleted_cards.map { |e| e.dig("card", "cid") }
  end

  test "a bin-only withdrawn card is purged even when the deck is already clean" do
    survey = build_survey(
      cards: [ card("rating", "c_a") ],
      deleted_cards: [ { "card" => neuro_card("c_binned"), "deleted_at" => "2026-08-01T00:00:00Z" } ]
    )

    assert_equal 0, LegacyCardPurge.purge_survey!(survey), "no deck cards were removed"
    assert_empty survey.reload.deleted_cards
  end

  # ── the deliberate bypass ──────────────────────────────────────────────────

  test "a published Verto with responses is purged despite being editing-locked" do
    survey = build_survey(cards: [ card("rating", "c_a"), contact_card ],
                          publish_token: SecureRandom.hex(6), published_at: Time.current)
    add_response!(survey, { "0" => answer(3), "1" => answer({ "name" => "Ada" }) })

    assert survey.editing_locked?, "fixture should be locked to the editor"
    assert_equal 1, LegacyCardPurge.purge_survey!(survey)
    assert_equal [ "c_a" ], survey.reload.cards.map { |c| c["cid"] }
  end

  # ── idempotency / no-op ────────────────────────────────────────────────────

  test "a second pass changes nothing" do
    survey = build_survey(cards: [ card("rating", "c_a"), contact_card, card("nps", "c_b") ])
    resp = add_response!(survey, { "0" => answer(1), "1" => answer({}), "2" => answer(8) })

    LegacyCardPurge.purge_survey!(survey)
    cards_after   = survey.reload.cards
    answers_after = resp.reload.answers

    assert_equal 0, LegacyCardPurge.purge_survey!(survey.reload)
    assert_equal cards_after, survey.reload.cards
    assert_equal answers_after, resp.reload.answers
  end

  test "a Verto with nothing withdrawn is left exactly as it was" do
    cards = [ card("rating", "c_a"), card("open_ended", "c_b") ]
    survey = build_survey(cards: cards, results_summary: "kept")
    resp = add_response!(survey, { "0" => answer(4), "1" => answer("hi") })
    before = survey.updated_at

    assert_equal 0, LegacyCardPurge.purge_survey!(survey)

    survey.reload
    assert_equal cards, survey.cards
    assert_equal({ "0" => answer(4), "1" => answer("hi") }, resp.reload.answers)
    assert_equal "kept", survey.results_summary
    assert_equal before.to_i, survey.updated_at.to_i, "an untouched Verto should not be restamped"
  end

  test "the cached AI summary is dropped so it cannot describe a question that is gone" do
    survey = build_survey(cards: [ card("rating", "c_a"), contact_card ],
                          results_summary: "12 contact-detail submissions",
                          results_summary_response_count: 12)

    LegacyCardPurge.purge_survey!(survey)

    survey.reload
    assert_nil survey.results_summary
    assert_nil survey.results_summary_response_count
  end
end
