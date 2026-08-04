require "test_helper"

# The editor feed scroll-snaps `y mandatory`, which per spec means the
# scroller can only ever REST on a snap target — anything else it springs off.
# So everything in the feed a creator has to click must itself be a target.
# The consent/thank-you add-CTAs live in .gate-cta-row, outside every card
# wrap, and weren't: scrolling to the bottom of the deck snapped straight back
# to the last card, so "＋ Thank-you screen" could be glimpsed mid-scroll but
# never clicked, and creators couldn't add the screen at all.
#
# Parsing CSS with a regex is crude (js_constant_parity_test makes the same
# trade-off for JS), but the assertions fail loudly if the rules move rather
# than silently passing.
class EditorScrollSnapTest < ActiveSupport::TestCase
  CSS_PATH = Rails.root.join("app/assets/tailwind/application.css")

  test "every clickable resting point in the mandatory-snap feed is a snap target" do
    css = File.read(CSS_PATH)
    skip "the editor feed no longer snaps mandatory — nothing to guard" unless
      css.match?(/\.editor-feed\s*\{[^}]*scroll-snap-type:\s*y mandatory/)

    %w[.survey-card-wrap .gate-card-wrap .gate-cta-row].each do |sel|
      assert css.match?(/\.editor-feed\s+#{Regexp.escape(sel)}[^{}]*\{[^}]*scroll-snap-align/),
             "#{sel} has no scroll-snap-align rule scoped to .editor-feed. Under " \
             "mandatory snapping the scroller cannot rest on it, so whatever it " \
             "offers (e.g. the thank-you/consent add-CTAs) snaps away before it " \
             "can be clicked."
    end
  end
end
