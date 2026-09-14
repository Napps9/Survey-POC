require "test_helper"

# The two anchor lines beside a liquid scale's ends — card["nps_low_label"] and
# card["nps_high_label"]. "We need a short line of text to the left of 0 and to
# the left of 10. This is so it's clear what the scale is."
#
# The column they live in is a SIBLING of the digits, not two more of them, and
# that is the load-bearing fact: the step count IS the label count
# (data-nps-slider-steps-value, aria-valuemax, and the positional key every
# stored answer is filed under), card-editor rebuilds the digit column wholesale
# when the Classic switch moves, and nps-slider indexes its label targets by
# step. An anchor that ended up inside that column would add a stop to the
# scale. So the count is asserted in every case below.
#
# Rendered through the partial rather than a whole page so the three surfaces
# can be compared directly — the same idiom as player_accessibility_test.
class NpsAnchorsRenderTest < ActionDispatch::IntegrationTest
  LOW  = "I have no say at all".freeze
  HIGH = "I am a decision maker".freeze

  def setup
    @org = Organisation.create!(name: "Unleash", slug: "anchors-#{SecureRandom.hex(3)}")
  end

  def survey_with(card, locales: [ "en" ])
    @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults",
                         key_insight: "k", default_locale: "en", locales: locales,
                         cards: [ card ])
  end

  def render_card(card, mode:, locale: "en")
    survey = survey_with(card, locales: [ "en", locale ].uniq)
    ApplicationController.render(partial: "shared/card_component",
                                 locals: { card: survey.cards.first, mode: mode,
                                           survey: survey, index: 0, locale: locale })
  end

  def anchored_card(extra = {})
    { "type" => "nps", "cid" => "n1", "text" => "How much say do you feel like you have?",
      "nps_low_label" => LOW, "nps_high_label" => HIGH }.merge(extra)
  end

  test "the player draws both anchors, read-only, beside an unchanged scale" do
    html = render_card(anchored_card, mode: :player)
    doc  = Nokogiri::HTML5.fragment(html)

    assert_equal LOW,  doc.at_css(".nps-anchor-low").text
    assert_equal HIGH, doc.at_css(".nps-anchor-high").text
    assert_nil doc.at_css(".nps-anchors [contenteditable]"),
               "a respondent must not be able to retype the creator's caption"
    assert_nil doc.at_css(".nps-anchors [data-placeholder]")

    assert_equal "11", doc.at_css(".nps-slider")["data-nps-slider-steps-value"]
    assert_equal "10", doc.at_css(".nps-slider")["aria-valuemax"]
    assert_equal 11, doc.css(".nps-label-row").length,
                 "the anchors are a second column — they must not become stops"
  end

  # The column has to come BEFORE the digits, because the digits come before the
  # vessel: the reading order is caption, number, liquid, and a column appended
  # after the vessel would put the captions on the wrong side of it.
  test "the anchors column sits before the digits inside the stage" do
    html = render_card(anchored_card, mode: :player)
    stage = Nokogiri::HTML5.fragment(html).at_css(".nps-slider-stage")

    assert_equal %w[nps-anchors slider-labels nps-control],
                 stage.element_children.map { |el| el["class"].to_s.split.first }
  end

  test "a card with no anchors draws no column at all on the player" do
    html = render_card({ "type" => "nps", "cid" => "n1", "text" => "How likely?" }, mode: :player)
    doc  = Nokogiri::HTML5.fragment(html)

    assert_nil doc.at_css(".nps-anchors"),
               "an empty column still costs a stage gap, which shifts the vessel"
    assert_equal 11, doc.css(".nps-label-row").length
  end

  # The editor's column is the FIELD, so it is there whether or not the creator
  # has written anything — an absent node is a caption that cannot be added.
  test "the editor draws two empty editable anchors with placeholders" do
    html = render_card({ "type" => "nps", "cid" => "n1", "text" => "How likely?" }, mode: :editor)
    doc  = Nokogiri::HTML5.fragment(html)

    low = doc.at_css(".nps-anchor-low")
    assert low, "with no node there is nowhere to type the caption"
    assert_equal "true", low["contenteditable"]
    assert_equal I18n.t("card.nps_low_placeholder"), low["data-placeholder"]
    assert_equal I18n.t("card.nps_high_placeholder"), doc.at_css(".nps-anchor-high")["data-placeholder"]

    # EMPTY, with no whitespace in it: the placeholder is an :empty::before, and
    # a newline inside the span is content as far as :empty is concerned.
    assert_equal "", low.inner_html
  end

  test "the editor prefills the anchors a card already carries" do
    doc = Nokogiri::HTML5.fragment(render_card(anchored_card, mode: :editor))

    assert_equal LOW,  doc.at_css(".nps-anchor-low").text
    assert_equal HIGH, doc.at_css(".nps-anchor-high").text
  end

  # The anchors are respondent-facing words, so they translate like the question
  # itself — a French respondent reading "I have no say at all" under a French
  # question is the thing localized_card exists to prevent.
  test "a translated anchor renders in the respondent's language" do
    card = anchored_card("i18n" => { "fr" => { "text" => "Quel pouvoir ?",
                                               "nps_low_label" => "Je n'ai aucun pouvoir",
                                               "nps_high_label" => "Je décide" } })
    doc = Nokogiri::HTML5.fragment(render_card(card, mode: :player, locale: "fr"))

    assert_equal "Je n'ai aucun pouvoir", doc.at_css(".nps-anchor-low").text
    assert_equal "Je décide", doc.at_css(".nps-anchor-high").text
  end

  test "an untranslated anchor falls back to the primary wording, like the question" do
    card = anchored_card("i18n" => { "fr" => { "text" => "Quel pouvoir ?" } })
    doc = Nokogiri::HTML5.fragment(render_card(card, mode: :player, locale: "fr"))

    assert_equal LOW, doc.at_css(".nps-anchor-low").text,
                 "the player renders the primary for an untranslated field everywhere else too"
  end

  # A custom scale is the case the captions were asked for — "the scales relate
  # to the question asked" — so the two features have to compose.
  test "anchors sit beside a shortened custom scale without changing its count" do
    card = anchored_card("options" => [ "Never", "Rarely", "Sometimes", "Often", "Always" ],
                         "nps_custom_scale" => true)
    doc = Nokogiri::HTML5.fragment(render_card(card, mode: :player))

    assert_equal "5", doc.at_css(".nps-slider")["data-nps-slider-steps-value"]
    assert_equal 5, doc.css(".nps-label-row").length
    assert_equal LOW, doc.at_css(".nps-anchor-low").text
  end
end
