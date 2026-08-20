require "test_helper"

# The mobile-keyboard fix, pinned at source — because no browser test can see
# it regress. Headless Chrome has no soft keyboard, so the behaviour these
# guard has no observable symptom in CI at all; the same crude-regex trade-off
# player_safe_area_test and player_hero_css_test make, and the same excuse.
#
# The bug: .preview-overlay is `position: fixed; inset: 0` PLUS
# `height: var(--app-100vh)`. Over-constrained, so `bottom` is dropped and
# `height` wins — the box is anchored to the top of the LAYOUT viewport but
# sized to the VISUAL one. They agree until a keyboard opens, at which point
# the overlay shrinks upward, bare <body> shows below it, and the in-flow
# footer is left stranded mid-screen.
class PlayerKeyboardViewportTest < ActiveSupport::TestCase
  VIEWPORT_JS = Rails.root.join("app/javascript/lib/viewport_height.js").freeze
  HEAD        = Rails.root.join("app/views/layouts/_head.html.erb").freeze

  def js
    @js ||= File.read(VIEWPORT_JS)
  end

  test "the keyboard is detected as a DELTA between the two viewports" do
    assert_match(/window\.innerHeight/, js,
                 "viewport_height.js no longer reads window.innerHeight. The delta between the " \
                 "layout and visual viewports IS the mechanism: it is how the file tells a " \
                 "browser toolbar (both shrink together) apart from a soft keyboard (only the " \
                 "visual one shrinks). Reading the visual viewport alone is the original bug.")
    assert_match(/visualViewport/, js, "the visual viewport reading is gone")
  end

  test "it stops publishing a height while a keyboard is up" do
    # The freeze is an ABSENCE — an early return — and absences are exactly
    # what a tidy-up deletes, so assert it exists and that it comes before the
    # write it is meant to skip.
    early_return = js.index(/if\s*\([^)]*KEYBOARD_DELTA[\s\S]{0,120}?\)\s*return/)
    set_property  = js.index("--app-100vh")

    assert early_return, "the keyboard early-return is gone — --app-100vh is tracking the " \
                         "keyboard again, which is what shrinks the overlay out from under the " \
                         "footer and shows bare <body> beneath it."
    assert_operator early_return, :<, js.rindex("setProperty"),
                    "the early return must precede the setProperty it guards"
    assert set_property, "--app-100vh is no longer published at all"
  end

  test "it re-measures on both edges of the keyboard" do
    assert_match(/focusin/, js)
    assert_match(/focusout/, js,
                 "without the focusout edge a frozen height outlives the keyboard that " \
                 "justified it: the visualViewport resize can fire while activeElement is " \
                 "still the field, so the close needs its own re-measure.")
  end

  test "the player asks Chrome to resize the layout viewport for the keyboard" do
    head = File.read(HEAD)

    assert_match(/interactive-widget=resizes-content/, head,
                 "the player's viewport meta lost interactive-widget=resizes-content. On " \
                 "Chrome/Android that hint is what makes the keyboard shrink the LAYOUT " \
                 "viewport, so `position: fixed; inset: 0` is genuinely the visible area and " \
                 "the footer rides above the keyboard instead of stranding.")
    assert_match(/controller_name == "player"/, head,
                 "the hint must stay scoped to the player — the editor is built for a pointer " \
                 "and the auth pages rely on the browser's ordinary scroll-into-view.")
  end
end
