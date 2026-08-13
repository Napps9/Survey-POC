# frozen_string_literal: true

require "test_helper"
require_relative "../../bin/week_summary_lib"

class WeekSummaryTest < ActiveSupport::TestCase
  MONDAY = Date.new(2026, 8, 10)

  def card(name, points: nil, desc: "", badges: nil, extra_labels: [])
    labels = extra_labels.map { |n| { "name" => n, "color" => "sky" } }
    labels << { "name" => points.to_s, "color" => "red" } if points
    { "name" => name, "desc" => desc, "labels" => labels, "badges" => badges }
  end

  def fixture_cards
    [
      card("Newest fix", points: 3, desc: "Top of list\n\n## Backend\nStuff",
           badges: { "checkItems" => 4, "checkItemsChecked" => 4 }),
      card("Big feature", points: 8, desc: "## Frontend\nUI\n\n## Backend\nAPI",
           badges: { "checkItems" => 4, "checkItemsChecked" => 3 }),
      card("Unpointed chore", desc: "No sections here"),
      card("Labelled oddity", points: 5, extra_labels: [ "urgent" ]),
      { "name" => "Week summary — 9 pts · 2 cards", "desc" => "old totals" }
    ]
  end

  test "aggregate sums points and counts, excluding the summary card" do
    totals = WeekSummary.aggregate(fixture_cards)
    assert_equal 4, totals["cards"]
    assert_equal 16, totals["points"]
    assert_equal 3, totals["pointed"]
    assert_equal 1, totals["unpointed"]
    assert_equal 1, totals["frontend"]
    assert_equal 2, totals["backend"]
    assert_equal 7, totals["checks_done"]
    assert_equal 8, totals["checks_total"]
  end

  test "aggregate tolerates empty and summary-only lists" do
    empty = WeekSummary.aggregate([])
    assert_equal 0, empty["cards"]
    assert_equal 0, empty["points"]

    only_summary = WeekSummary.aggregate([ { "name" => "Week summary — 1 pts · 1 card" } ])
    assert_equal 0, only_summary["cards"]
  end

  test "points_for ignores non-points labels and takes the max of duplicates" do
    assert_nil WeekSummary.points_for(card("x", extra_labels: [ "urgent", "42" ]))
    doubled = card("x", points: 3)
    doubled["labels"] << { "name" => "8", "color" => "purple" }
    assert_equal 8, WeekSummary.points_for(doubled)
  end

  test "summary_card? matches the reserved prefix only" do
    assert WeekSummary.summary_card?({ "name" => "Week summary — 0 pts · 0 cards" })
    assert_not WeekSummary.summary_card?({ "name" => "Weekly digest improvements" })
  end

  test "card_name pluralizes" do
    assert_equal "Week summary — 16 pts · 4 cards", WeekSummary.card_name(WeekSummary.aggregate(fixture_cards))
    assert_equal "Week summary — 5 pts · 1 card",
                 WeekSummary.card_name({ "points" => 5, "cards" => 1 })
  end

  test "fallback_highlights ranks by points, keeps list order on ties, and caps" do
    text = WeekSummary.fallback_highlights(fixture_cards)
    assert_equal [ "- Big feature (8 pts)", "- Labelled oddity (5 pts)",
                   "- Newest fix (3 pts)", "- Unpointed chore (unpointed)" ], text.lines.map(&:chomp)

    many = Array.new(20) { |i| card("Card #{i}", points: 1) }
    capped = WeekSummary.fallback_highlights(many)
    assert_equal WeekSummary::FALLBACK_BULLET_CAP + 1, capped.lines.size
    assert_match(/\A- …and 5 more cards\z/, capped.lines.last.chomp)
  end

  test "build_claude_user truncates descriptions and marks unpointed cards" do
    long = card("Talker", desc: "line one\nline two #{'x' * 300}")
    msg = WeekSummary.build_claude_user([ long, card("Quiet", points: 2) ],
                                        MONDAY, { "cards" => 2, "points" => 2 })
    assert_includes msg, "Week of 10th August 2026 — 2 cards, 2 story points"
    assert_includes msg, "- [? pts] Talker — line one line two"
    assert_includes msg, "- [2 pts] Quiet"
    snippet = msg[/Talker — (.*)$/, 1]
    assert_operator snippet.length, :<=, WeekSummary::DESC_SNIPPET_CHARS
  end

  test "extract_bullets strips prose, normalizes asterisks, caps at 8, nil when none" do
    text = "Here is the summary:\n* First theme\n- Second theme\nclosing remark"
    assert_equal "- First theme\n- Second theme", WeekSummary.extract_bullets(text)
    assert_equal 8, WeekSummary.extract_bullets(Array.new(12) { |i| "- b#{i}" }.join("\n")).lines.size
    assert_nil WeekSummary.extract_bullets("no bullets in sight")
    assert_nil WeekSummary.extract_bullets(nil)
  end

  test "render_desc lays out heading, totals, highlights, footer" do
    desc = WeekSummary.render_desc(totals: WeekSummary.aggregate(fixture_cards),
                                   highlights_md: "- Something shipped",
                                   monday: MONDAY, generated_on: Date.new(2026, 8, 16),
                                   source: "claude")
    assert_includes desc, "# Week of 10th August 2026 (Mon 10 Aug – Sun 16 Aug)"
    assert_includes desc, "**16 story points** across 4 cards (3 pointed, 1 unpointed)"
    assert_includes desc, "Frontend: 1 · Backend: 2"
    assert_includes desc, "Test checklists: 7/8 items passing"
    assert_includes desc, "- Something shipped"
    assert_includes desc, "_Generated 2026-08-16 by bin/trello_week_summary · highlights: claude_"
  end

  test "render_desc omits the checklist line when no card has one and truncates at the cap" do
    no_checks = WeekSummary.render_desc(totals: WeekSummary.aggregate([ card("x", points: 1) ]),
                                        highlights_md: "- x", monday: MONDAY,
                                        generated_on: Date.new(2026, 8, 16), source: "fallback")
    assert_not_includes no_checks, "Test checklists"

    huge = WeekSummary.render_desc(totals: WeekSummary.aggregate([]),
                                   highlights_md: "y" * 17_000, monday: MONDAY,
                                   generated_on: Date.new(2026, 8, 16), source: "fallback")
    assert_operator huge.length, :<=, 16_384
    assert huge.end_with?("… [truncated]")
  end
end
