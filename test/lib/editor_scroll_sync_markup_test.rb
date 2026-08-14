require "test_helper"

# editor-scroll-sync re-points the right-hand editor panel at whichever card the
# creator has scrolled to. It is entirely wiring: a controller mounted on the
# editor root, an IntersectionObserver root on the feed, and one target per card.
# Drop any single attribute and the feature doesn't break loudly — it silently
# does nothing, and the panel goes back to editing whatever was last clicked.
#
# The browser tests that prove the behaviour live in test/system, which Rails
# keeps out of `bin/rails test` and CI runs as its own job. So these cheap
# assertions stand in the fast suite, where they'll fail on the commit that
# removed the wiring rather than a deploy later.
#
# Parsing markup with a regex is crude (editor_scroll_snap_test makes the same
# trade-off for CSS), but the assertions fail loudly if the attributes move
# rather than silently passing.
class EditorScrollSyncMarkupTest < ActiveSupport::TestCase
  EDITOR   = Rails.root.join("app/views/surveys/show.html.erb")
  CARD_ROW = Rails.root.join("app/views/surveys/_card_row.html.erb")

  test "the editor root mounts editor-scroll-sync alongside type-panel" do
    html = File.read(EDITOR)
    controllers = html[/data-controller="([^"]*type-panel[^"]*)"/, 1]
    assert controllers, "couldn't find the editor root's data-controller list"
    assert_includes controllers.split, "editor-scroll-sync",
      "the editor root must mount editor-scroll-sync. It reaches type-panel via " \
      "getControllerForElementAndIdentifier(this.element, ...), which only " \
      "resolves for controllers on the SAME element."
  end

  test "the feed, grid and panel each name themselves to editor-scroll-sync" do
    html = File.read(EDITOR)
    {
      "feed"  => "the IntersectionObserver root — without it the observer is never built",
      "grid"  => "read for .is-panel-open, the guard that stops a scroll opening the panel",
      "panel" => "the focus guard — without it a scroll can re-point the panel mid-keystroke"
    }.each do |name, why|
      assert_includes html, %(data-editor-scroll-sync-target="#{name}"),
        "show.html.erb is missing the #{name} target: #{why}."
    end
  end

  test "every card names itself to editor-scroll-sync from the shared partial" do
    assert_includes File.read(CARD_ROW), 'data-editor-scroll-sync-target="card"',
      "_card_row.html.erb must carry the card target. Cards added after page " \
      "load (insert, duplicate, restore, generate) are re-rendered from THIS " \
      "partial by RendersCardHtml — declaring the target anywhere else leaves " \
      "them unobserved, so scrolling to a new card would never select it."
  end

  test "cardSelected arms the scroll-sync suppression window" do
    html = File.read(EDITOR)
    assert_includes html, "type-panel:cardSelected->editor-scroll-sync#armSuppression",
      "a click-selection must arm the suppression window. Several call sites " \
      "scrollIntoView the card they just clicked, and opening the panel reflows " \
      "the feed — unsuppressed, the sync reads those back as a creator scroll."
    assert_includes html, "focusout->editor-scroll-sync#focusOut",
      "without the focusout hook, a re-target deferred while the panel had focus " \
      "is never applied — the panel stays on the old card indefinitely."
  end
end
