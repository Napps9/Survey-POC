require "test_helper"

# The safe-area inset has to be on the element that touches the bezel.
#
# It was on `.split-right` — the white content panel, two boxes up from the
# bottom of the screen — where it did nothing but eat ~34px of card interior on
# every home-indicator phone. `.preview-footer`, which IS the bottom-most
# element and holds Back and Next, asked for nothing. The two mistakes compound
# instead of cancelling: on a phone added to the home screen (display:
# standalone, so no browser chrome underneath) the bottom ~16px of both buttons
# sat under the home indicator, where iOS claims the swipe before the button
# ever sees the tap.
#
# A source assertion rather than a browser one, deliberately: env(safe-area-
# inset-bottom) resolves to 0px on every headless Chrome, so a system test can
# watch the buttons sit happily on screen while shipping exactly this bug. What
# can be checked is which rule asks for the inset, and that is the thing that
# regressed. Same trade-off (and same crude regex) as editor_scroll_snap_test.
class PlayerSafeAreaTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/tailwind/application.css").freeze

  def css
    @css ||= File.read(CSS)
  end

  # Body of the LAST rule whose selector matches, since these live inside the
  # mobile media query and later rules are the ones in force there.
  def rule_bodies(selector)
    css.scan(/#{Regexp.escape(selector)}\s*\{([^}]*)\}/).flatten
  end

  test "the footer asks for the safe-area inset" do
    bodies = rule_bodies(".preview-overlay .preview-footer")

    assert bodies.any?, "no .preview-overlay .preview-footer rule found at all"
    assert bodies.any? { |b| b.match?(/padding-bottom:\s*env\(safe-area-inset-bottom/) },
           "the player footer no longer pads for env(safe-area-inset-bottom). It is the " \
           "bottom-most element on the card and it holds Back and Next — without this, " \
           "the bottom of both buttons sits under the home indicator on a standalone PWA."
  end

  # `height` would make the padding eat into the bar instead of adding to it
  # (border-box sizing), which moves the buttons up without making room below —
  # the inset would be declared and still not work.
  test "the footer is sized so the inset can add to it" do
    body = rule_bodies(".preview-overlay .preview-footer")
             .find { |b| b.include?("padding-bottom") }

    assert_match(/height:\s*auto/, body,
                 "the footer needs height:auto for the safe-area padding to ADD to the bar; " \
                 "with a fixed height and border-box sizing it eats the bar instead.")
    assert_match(/min-height:/, body, "height:auto still needs a min-height to hold the touch target")
  end

  test "the content panel no longer pads for a bezel it does not touch" do
    bodies = rule_bodies(".preview-overlay .split-card .split-right")

    assert bodies.any?, "no .split-right rule found — has the player layout been renamed?"
    bodies.each do |b|
      refute_match(/env\(safe-area-inset-bottom/, b,
                   ".split-right is padding for the safe area again. It is not the bottom-most " \
                   "element; the footer below it is. This costs ~34px of answer area and leaves " \
                   "the buttons that DO touch the indicator unprotected.")
    end
  end
end
