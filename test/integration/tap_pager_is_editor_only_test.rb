require "test_helper"

# The tap card's statement pager is the CREATOR's way through a deck, and it
# must never reach a respondent.
#
# It is the one piece of editor chrome that does not sit beside a respondent
# control — it takes one's place. `_card_component` renders the pager in
# :editor mode INSTEAD of the reset row, because the two modes want opposite
# things from the deck: a creator walks it, a respondent takes answers back. So
# a surface that leaks the pager doesn't just gain a control it shouldn't have,
# it LOSES Reset at the same time.
#
# That is exactly what happened to the editor's preview overlay, which is not
# rendered by this partial at all: preview_verto_controller deep-clones the
# editor's live card DOM and strips the editor-only chrome by selector, and the
# pager was not on the strip list. Its regression test is the system one
# (test/system/tap_preview_chrome_test.rb) since only a browser runs that clone.
#
# What this file holds is the server-rendered half — the published player and
# Test Mode, the two the owner asked to be sure of — through the real routes
# rather than the partial alone, so a controller that ever passed mode: :editor
# by mistake is caught too.
class TapPagerIsEditorOnlyTest < ActionDispatch::IntegrationTest
  PAGER = "tap-nav-row".freeze
  RESET = "rotate-reset-btn".freeze

  def setup
    @org = Organisation.create!(name: "O", slug: "pager-#{SecureRandom.hex(3)}")
    @survey = @org.surveys.create!(
      title: "Deck", theme: "Th", audience_age: "adults", key_insight: "k",
      default_locale: "en", locales: [ "en" ],
      cards: [
        { "type" => "welcome_card", "title" => "Hello" },
        { "type" => "tap_card", "cid" => "t1", "text" => "React to these",
          "options" => [ "One", "Two", "Three" ] }
      ]
    )
    @survey.update_columns(publish_token: SecureRandom.hex(8),
                           test_token: SecureRandom.hex(8),
                           published_at: Time.current)
  end

  def render_card(mode)
    ApplicationController.render(
      partial: "shared/card_component",
      locals: { card: @survey.cards.last, mode: mode, survey: @survey, index: 0 }
    )
  end

  test "the editor is the only mode whose tap card carries the pager" do
    editor = render_card(:editor)
    assert_includes editor, PAGER, "the creator lost the only way through the deck"
    assert_not_includes editor, RESET,
                        "the editor should carry the pager INSTEAD of Reset, not as well as — " \
                        "two rows that do overlapping jobs is the clutter the swap avoids"

    [ :player, :preview ].each do |mode|
      html = render_card(mode)
      assert_not_includes html, PAGER, "mode: #{mode} rendered the creator's statement pager"
      assert_includes html, RESET, "mode: #{mode} lost the respondent's Reset control"
    end
  end

  test "the published player serves no pager" do
    get play_survey_path(@survey.publish_token)
    assert_response :success
    assert_not_includes response.body, PAGER,
                        "a respondent on the live link can page through the deck as if editing it"
    assert_includes response.body, RESET
  end

  test "Test Mode serves no pager" do
    get test_survey_path(@survey.test_token)
    assert_response :success
    assert_not_includes response.body, PAGER,
                        "Test Mode is meant to be the exact respondent experience — a pager here " \
                        "means whoever is being shown the Verto is not seeing what ships"
    assert_includes response.body, RESET
  end
end
