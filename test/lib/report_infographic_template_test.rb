require "test_helper"

# The share card template (RenderInfographicJob's HTML, before it goes through
# WickedPdf) — pure ERB, no PDF binary involved, so this stays fast and
# doesn't need the render job's own end-to-end coverage
# (results_reports_test.rb) to prove the content itself is right.
class ReportInfographicTemplateTest < ActiveSupport::TestCase
  def build_survey(theme: "Neighbourhood Voices")
    org = Organisation.create!(name: "O", slug: "rit-#{SecureRandom.hex(3)}")
    org.surveys.create!(title: "T", theme: theme, audience_age: "all", key_insight: "k",
                        default_locale: "en", locales: [ "en" ],
                        cards: [ { "type" => "multiple_choice", "text" => "Favourite park?", "options" => %w[North South] } ])
  end

  def render_card(survey, stats:, aggregated:)
    ApplicationController.render(
      template: "results_reports/infographic", formats: [ :html ], layout: false,
      locals: { survey: survey, stats: stats, aggregated: aggregated }
    )
  end

  test "carries the survey theme, headline stats, and a question's top bars" do
    survey = build_survey
    stats  = { responders: 42, completed: 40, completion: 95, questions: 3 }
    aggregated = [
      { card: survey.cards.first, type: "multiple_choice", total: 42,
        counts: { "North" => 30, "South" => 12 } }
    ]

    html = render_card(survey, stats: stats, aggregated: aggregated)

    assert_includes html, "Neighbourhood Voices"
    assert_includes html, "42"
    assert_includes html, "95%"
    assert_includes html, "Favourite park?"
    assert_includes html, "North"
    assert_includes html, "71%" # 30/42 rounded — ReportChartRows.rows_for's own pct math
  end

  test "a question with only one answer category doesn't render as a chart — a one-bar bar chart is a stat wearing a costume" do
    survey = build_survey
    aggregated = [
      { card: survey.cards.first, type: "multiple_choice", total: 5, counts: { "North" => 5 } }
    ]

    html = render_card(survey, stats: { responders: 5, completed: 5, completion: 100, questions: 1 }, aggregated: aggregated)
    refute_includes html, 'class="bar-row"'
  end

  test "with no chartable questions at all the card still renders — just the brand and stats" do
    survey = build_survey
    html = render_card(survey, stats: { responders: 0, completed: 0, completion: 0, questions: 1 }, aggregated: [])

    assert_includes html, "playverto"
    refute_includes html, 'class="bar-row"'
  end

  test "caps at two questions even when more are chartable — a share card is read in seconds" do
    survey = build_survey
    survey.update!(cards: [
      { "type" => "multiple_choice", "text" => "Q1", "options" => %w[A B] },
      { "type" => "multiple_choice", "text" => "Q2", "options" => %w[A B] },
      { "type" => "multiple_choice", "text" => "Q3", "options" => %w[A B] }
    ])
    aggregated = survey.cards.map do |card|
      { card: card, type: "multiple_choice", total: 4, counts: { "A" => 3, "B" => 1 } }
    end

    html = render_card(survey, stats: { responders: 4, completed: 4, completion: 100, questions: 3 }, aggregated: aggregated)

    assert_includes html, "Q1"
    assert_includes html, "Q2"
    refute_includes html, "Q3"
  end

  test "a long theme is truncated rather than overflowing the fixed-size card" do
    survey = build_survey(theme: "A" * 200)
    html = render_card(survey, stats: { responders: 0, completed: 0, completion: 0, questions: 0 }, aggregated: [])

    assert_no_match(/A{100,}/, html)
  end
end
