require "test_helper"

# Which ink a mobile background carries is decided in TWO places: the editor
# measures the creator's pick (app/javascript/lib/backdrop_ink.js) and the
# server sanitises what it sends and decides for itself when nothing measured
# — an import, a seed, a plain colour (Survey.backdrop_ink_for_color).
#
# Two implementations of one judgement is the shape that goes stale, and the
# failure is quiet: nobody sees an exception, a card just renders white words
# on a pale background. There is no JS runtime here, so this pins what can be
# pinned — the shared threshold, read out of the module, and the Ruby side's
# behaviour at the boundaries either implementation would get wrong first.
class BackdropInkParityTest < ActiveSupport::TestCase
  JS = Rails.root.join("app/javascript/lib/backdrop_ink.js").freeze

  def js_source
    @js_source ||= File.read(JS)
  end

  test "the threshold is the same number on both sides" do
    match = js_source[/export const LIGHT_BACKDROP_THRESHOLD\s*=\s*([\d.]+)/, 1]

    assert match, "backdrop_ink.js no longer exports LIGHT_BACKDROP_THRESHOLD — this test can " \
                  "no longer see the constant it guards"
    assert_in_delta Survey::LIGHT_BACKDROP_THRESHOLD, match.to_f, 0.0001,
                    "the editor measures a picture against #{match} and the server measures a " \
                    "colour against #{Survey::LIGHT_BACKDROP_THRESHOLD}. The same backdrop " \
                    "would get different ink depending on which one saw it."
  end

  test "the JS reads the WCAG curve, not a channel average" do
    # A mean of R/G/B calls a saturated blue light and a saturated yellow dark,
    # which is the wrong way round for both — the coefficients are the whole
    # reason this agrees with the Ruby.
    assert_match(/0\.2126/, js_source)
    assert_match(/0\.7152/, js_source)
    assert_match(/0\.0722/, js_source)
  end

  test "a light colour takes dark ink and a dark colour takes light ink" do
    assert_equal "dark",  Survey.backdrop_ink_for_color("#ffffff")
    assert_equal "dark",  Survey.backdrop_ink_for_color("#f2f2f2")
    assert_equal "light", Survey.backdrop_ink_for_color("#000000")
    assert_equal "light", Survey.backdrop_ink_for_color("#2e3564"), "the app's own navy"
  end

  # The two that a channel average gets wrong, and the reason the curve is
  # worth carrying twice: yellow is far lighter than its numbers suggest and
  # blue far darker.
  test "saturated yellow is a light background and saturated blue is a dark one" do
    assert_equal "dark",  Survey.backdrop_ink_for_color("#ffd800"),
                 "yellow is a light background — white words on it are unreadable"
    assert_equal "light", Survey.backdrop_ink_for_color("#0000ff"),
                 "a saturated blue is dark, whatever its channel average says"
  end

  test "junk gets no ink rather than a guessed one" do
    assert_nil Survey.backdrop_ink_for_color(nil)
    assert_nil Survey.backdrop_ink_for_color("")
    assert_nil Survey.backdrop_ink_for_color("rebeccapurple")
    assert_nil Survey.sanitize_backdrop_ink("chartreuse")
    assert_nil Survey.sanitize_backdrop_ink(nil)
    assert_equal "dark", Survey.sanitize_backdrop_ink(" DARK ")
  end
end
