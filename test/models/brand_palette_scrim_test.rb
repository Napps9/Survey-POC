require "test_helper"

# The scrim behind the end screen's words, as arithmetic.
#
# The thank-you card lost its opaque surface on 2026-09-14 (the owner's
# one-column pick), which put the title, the subtitle and the wordmark on the
# Verto's BACKGROUND PHOTO. A photo can be any brightness, so legibility there
# is not something a designer can check once — it has to be a property of the
# colour the scrim is painted in, for every palette a creator can pick.
#
# BrandPalette#readable_surface is that property, and this file is its proof.
# It is deliberately NOT a browser test: a pixel sample answers "was it right
# on the four backgrounds we happen to ship", and this answers "is it right for
# any photo at all", which is the actual question. The DOM half — that the
# scrim is really behind the text — is EndScreenContrastTest.
class BrandPaletteScrimTest < ActiveSupport::TestCase
  AA_BODY = 4.5

  # The brightest thing a background photo can present to the scrim.
  WHITE = "#FFFFFF"

  def composite_over_white(hex)
    BrandPalette.send(:over_white, hex)
  end

  def scrim_hex(bg)
    BrandPalette.send(:readable_surface, BrandPalette.resolve("bg" => bg)["bg"])
  end

  # Every corner of the space a creator can pick from, plus the pathological
  # ones: pure white, pure black, a mid-tone that is neither, and fully
  # saturated primaries where one channel does all the luminance work.
  PALETTES = %w[
    #1C2034 #FFFFFF #000000 #808080 #F3F1EA #0B1020 #2B1A1F #2F7F76
    #FF0000 #00FF00 #0000FF #FFFF00 #00FFFF #FF00FF #7F7F00 #123456
    #E8E8F0 #FAFAFA #C0C0C0 #4A4A4A
  ].freeze

  test "white text clears AA on the scrim over a white photo, for every palette" do
    failures = PALETTES.filter_map do |bg|
      hex = scrim_hex(bg)
      measured = BrandPalette.contrast_ratio(WHITE, composite_over_white(hex))
      next if measured >= AA_BODY

      format("bg %s → scrim %s → %.2f:1", bg, hex, measured)
    end
    assert_empty failures,
                 "the scrim is not dark enough to carry white text once composited over the " \
                 "brightest photo a Verto can have:\n  " + failures.join("\n  ")
  end

  # The bug the first attempt shipped with, kept as a test because it is the
  # easy mistake: a colour that carries white text AT FULL STRENGTH does not
  # necessarily carry it at SCRIM_ALPHA over a photo. #757470 measures 4.68:1
  # on its own and 2.3:1 composited — a fail wearing a pass's clothes.
  test "the derivation measures the composite, not the colour on its own" do
    naive = "#757470"
    assert_operator BrandPalette.contrast_ratio(WHITE, naive), :>=, AA_BODY,
                    "this colour is supposed to look fine in isolation — that is the trap"
    assert_operator BrandPalette.contrast_ratio(WHITE, composite_over_white(naive)), :<, AA_BODY,
                    "and to fail once composited, which is what the derivation has to catch"

    # So a pale cream must NOT resolve to anything that weak.
    assert_operator BrandPalette.contrast_ratio(WHITE, composite_over_white(scrim_hex("#F3F1EA"))),
                    :>=, AA_BODY
  end

  # "The colours are important" (owner, 2026-09-14). darken multiplies all
  # three channels, so a Verto tinted teal stays teal and one tinted coral
  # stays coral — the scrim is the creator's colour made legible, not a grey
  # slab dropped over their design.
  test "the scrim keeps the palette's hue" do
    { "#2F7F76" => :g, "#7F2F2F" => :r, "#2F357F" => :b }.each do |bg, dominant|
      r, g, b = BrandPalette.send(:rgb, scrim_hex(bg))
      channels = { r: r, g: g, b: b }
      assert_equal dominant, channels.max_by { |_, v| v }.first,
                   "#{bg} resolved to #{scrim_hex(bg)}, which is no longer that hue"
    end
  end

  # A dark palette is already legible and must come back untouched — the
  # derivation is a floor, not a filter that repaints everything it sees.
  test "a palette that already clears the floor is left exactly as it is" do
    %w[#1C2034 #0B1020 #2B1A1F #000000].each do |bg|
      assert_equal bg.downcase, scrim_hex(bg).downcase,
                   "#{bg} already carries white text and should not have been darkened"
    end
  end

  test "resolve exposes the scrim and its zero-alpha twin, ready for CSS" do
    r = BrandPalette.resolve("bg" => "#2F7F76")
    assert_match(/\Argba\(\d+, \d+, \d+, 0\.72\)\z/, r["scrim"])
    assert_match(/\Argba\(\d+, \d+, \d+, 0\)\z/, r["scrim_fade"],
                 "a gradient fading to `transparent` goes through transparent BLACK and " \
                 "leaves a grey fringe; it has to fade to its own colour at zero alpha")
    assert_equal r["scrim"].sub(/, 0\.72\)\z/, ", 0)"), r["scrim_fade"],
                 "the two must be the same colour, or the halo changes hue as it fades"
  end

  test "a malformed colour falls back rather than returning nil into CSS" do
    assert_equal BrandPalette::DEFAULT["bg"], BrandPalette.send(:readable_surface, "not-a-colour")
    assert_equal BrandPalette::DEFAULT["bg"], BrandPalette.send(:readable_surface, nil)
  end
end
