require "test_helper"

# P2-4. The player's answer options were `<li>` elements with a click handler:
# fine with a mouse or a thumb, unusable with a keyboard or a screen reader.
# They weren't focusable, and nothing announced them as choices or said which
# one was chosen. That covers multiple_choice, select_many, yes_no and both
# grids — most of what a respondent is ever asked — so a keyboard-only or
# screen-reader respondent could not answer at all.
#
# The same partial renders the editor, where those elements hold contenteditable
# option text, so the semantics are applied only outside it. Both halves are
# asserted here: a missing role in the player is the bug, and a stray role in
# the editor would announce edit fields as form controls.
class PlayerAccessibilityTest < ActionDispatch::IntegrationTest
  def setup
    @org = Organisation.create!(name: "O", slug: "a11y-#{SecureRandom.hex(3)}")
  end

  def render_card(card, mode:)
    survey = @org.surveys.create!(title: "T", theme: "Th", audience_age: "adults",
                                  key_insight: "k", default_locale: "en", locales: [ "en" ],
                                  cards: [ card ])
    ApplicationController.render(partial: "shared/card_component",
                                 locals: { card: survey.cards.first, mode: mode,
                                           survey: survey, index: 0 })
  end

  CARDS = {
    "multiple_choice" => { "type" => "multiple_choice", "cid" => "c", "text" => "Pick one",
                           "options" => %w[Red Blue] },
    "select_many"     => { "type" => "select_many", "cid" => "c", "text" => "Pick some",
                           "options" => %w[Red Blue] },
    "yes_no"          => { "type" => "yes_no", "cid" => "c", "text" => "Agree?",
                           "options" => %w[Yes No] },
    "select_one_grid" => { "type" => "select_one_grid", "cid" => "c", "text" => "Pick one",
                           "options" => %w[Red Blue] },
    "select_many_grid" => { "type" => "select_many_grid", "cid" => "c", "text" => "Pick some",
                            "options" => %w[Red Blue] }
  }.freeze

  SINGLE = %w[multiple_choice yes_no select_one_grid].freeze

  test "every choice option is focusable in the player" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      assert_equal 2, html.scan(/tabindex="0"/).size,
                   "#{name}: both options should be reachable by keyboard"
    end
  end

  test "options carry the role that matches the card's selection mode" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      expected = SINGLE.include?(name) ? "radio" : "checkbox"
      assert_equal 2, html.scan(/role="#{expected}"/).size,
                   "#{name}: options should be announced as #{expected}"
    end
  end

  test "options start unchecked and say so" do
    # A radio a screen reader can focus but never hear the state of is barely
    # better than none, so the attribute has to be present from the start —
    # not added on first selection.
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      assert_equal 2, html.scan(/aria-checked="false"/).size, "#{name}"
    end
  end

  test "the option set is announced as one group" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      expected = SINGLE.include?(name) ? "radiogroup" : "group"
      assert_includes html, %(role="#{expected}"), "#{name}: options should form a #{expected}"
    end
  end

  test "options bind a keyboard activator" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :player)
      assert_includes html, "keydown->picker#pickOnKey", "#{name}"
    end
  end

  test "the decorative tile is hidden from assistive tech" do
    # The icon tile repeats the option label visually; announcing it would read
    # every choice twice.
    html = render_card(CARDS["multiple_choice"], mode: :player)
    assert_includes html, 'class="choice-list-tile choice-bg-1" aria-hidden="true"'
  end

  # ── The editor must NOT get any of it ───────────────────────────────────

  test "the editor keeps plain list items" do
    CARDS.each do |name, card|
      html = render_card(card, mode: :editor)
      assert_equal 0, html.scan(/role="radio"/).size,    "#{name}: editor options must not be radios"
      assert_equal 0, html.scan(/role="checkbox"/).size, "#{name}: editor options must not be checkboxes"
      assert_equal 0, html.scan(/tabindex="0"/).size,    "#{name}: editor options must not be focusable"
      assert_equal 0, html.scan(/aria-checked/).size,    "#{name}"
    end
  end

  test "the editor does not bind the keyboard activator" do
    # Not shipping the binding at all there is one fewer thing that can misfire
    # while someone is typing an option label.
    CARDS.each do |name, card|
      assert_not_includes render_card(card, mode: :editor), "pickOnKey", "#{name}"
    end
  end

  test "the editor still binds the click picker" do
    # The guard must not have cost the editor its own behaviour.
    CARDS.each do |name, card|
      assert_includes render_card(card, mode: :editor), "click->picker#pick", "#{name}"
    end
  end

  # ── Controls that were already right ────────────────────────────────────

  test "the tap-card actions keep their labels" do
    html = render_card({ "type" => "tap_card", "cid" => "c", "text" => "Statements",
                         "options" => [ "One" ] }, mode: :player)
    assert_equal 3, html.scan(/aria-label=/).size,
                 "the three swipe actions should stay labelled"
  end
end
