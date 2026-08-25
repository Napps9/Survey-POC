require "test_helper"

# The "panel" role exists because the left media panel used to paint
# lighten(bg, 13%) — a colour nobody picked — behind every card. What these
# pin: an unset panel now follows the picked background EXACTLY, an explicit
# panel wins, and every Verto that predates the role renders unchanged.
class BrandPaletteTest < ActiveSupport::TestCase
  test "an unset panel follows the picked background exactly" do
    resolved = BrandPalette.resolve("primary" => "#112233", "cta" => "#445566", "bg" => "#151a2e")

    assert_equal "#151a2e", resolved["panel"],
                 "the panel not matching the picked hex is the reported bug"
  end

  test "an explicitly picked panel wins over the background" do
    resolved = BrandPalette.resolve("bg" => "#151a2e", "panel" => "#aabbcc")

    assert_equal "#aabbcc", resolved["panel"]
    assert_equal "#151a2e", resolved["bg"]
  end

  test "a palette with neither bg nor panel keeps the legacy panel colour" do
    resolved = BrandPalette.resolve("primary" => "#112233")

    assert_equal BrandPalette::DEFAULT["panel"].downcase, resolved["panel"].downcase,
                 "default bg must keep the legacy #2E3564 panel, matching the CSS fallback"
  end

  # Wizard submissions have always stored the default palette EXPLICITLY, so
  # this is the back-compat load-bearing case: those Vertos must go on
  # emitting no CSS vars (falling back to the stock Playverto look) even
  # though they only carry three of the now-four roles.
  test "a stored three-role default palette still counts as default" do
    legacy_default = { "primary" => "#01EACB", "cta" => "#01EACB", "bg" => "#1C2034" }

    assert BrandPalette.default?(legacy_default)
    assert BrandPalette.default?(nil)
    assert BrandPalette.default?({})
    assert BrandPalette.default?(BrandPalette::DEFAULT)
  end

  test "customising any role, including panel alone, is not default" do
    refute BrandPalette.default?("panel" => "#aabbcc")
    refute BrandPalette.default?("primary" => "#112233")
  end

  test "sanitize keeps a valid panel and drops an invalid one" do
    assert_equal({ "panel" => "#aabbcc" }, BrandPalette.sanitize("panel" => "#AABBCC"))
    assert_empty BrandPalette.sanitize("panel" => "not-a-hex")
  end

  # ── primary_ink ──────────────────────────────────────────────────────────
  #
  # "The selected option turns brand colour" is a rule that works for some
  # brands and silently fails for others, and nothing was checking which. On
  # the Playverto default (#01EACB) a chosen answer's label measured 1.47:1
  # against the row's own tint, having been 15.1:1 a moment earlier. A dark
  # brand hides it completely — which is why it went unreported for so long.
  #
  # The surface these are measured against is the one the label really sits on:
  # primary_soft is rgba(primary, 0.12), and compositing that onto white is
  # exactly lighten(primary, 0.88).
  AA_TEXT = 4.5

  def selected_surface(hex) = BrandPalette.lighten(hex, 0.88)

  test "a light brand's selected label is darkened until it is readable" do
    ink = BrandPalette.resolve("primary" => "#01EACB")["primary_ink"]
    surface = selected_surface("#01EACB")

    assert_operator BrandPalette.contrast_ratio("#01EACB", surface), :<, 2.0,
                    "the raw default primary is supposed to be the unreadable case this " \
                    "derivation exists for — if it now passes on its own, re-check the maths"
    assert_operator BrandPalette.contrast_ratio(ink, surface), :>=, AA_TEXT,
                    "#{ink} on #{surface} is still under #{AA_TEXT}:1. A respondent choosing " \
                    "an answer must not make its label harder to read than it was unchosen."
  end

  # Every one of these is a colour a client could plausibly pick, and every one
  # of them is illegible raw.
  { "lime" => "#C6FF3D", "pale pink" => "#FFC0CB", "yellow" => "#FFD400",
    "mint" => "#7CFFC4", "sky" => "#8ED8FF" }.each do |name, hex|
    test "a #{name} brand still yields a readable selected label" do
      ink = BrandPalette.resolve("primary" => hex)["primary_ink"]

      assert_operator BrandPalette.contrast_ratio(ink, selected_surface(hex)), :>=, AA_TEXT,
                      "#{name} (#{hex}) derived #{ink}, which is still too pale to read"
    end
  end

  test "a brand that is already readable is left exactly alone" do
    # The derivation must not repaint a brand that was fine. Darkening a mid
    # blue "for consistency" would be changing a colour the creator chose for
    # no reason a respondent could see.
    %w[#2E5AAC #1C2034 #7B2D8E #8A2B2B].each do |hex|
      resolved = BrandPalette.resolve("primary" => hex)
      # sanitize downcases, so compare on the value not the casing.
      assert_equal hex.downcase, resolved["primary_ink"].downcase,
                   "#{hex} already clears #{AA_TEXT}:1 and was altered anyway"
    end
  end

  test "the derived ink keeps the brand's hue rather than falling back to grey" do
    # darken() multiplies all three channels, so the ratios between them — the
    # hue — survive. This is the difference between "your brand, readable" and
    # "some dark colour": contrast_text would have returned #1C2034 for every
    # one of these.
    ink = BrandPalette.resolve("primary" => "#01EACB")["primary_ink"]
    r, g, b = BrandPalette.rgb(ink)

    assert_operator g, :>, r, "the green channel should still dominate a teal"
    assert_operator b, :>, r, "the blue channel should still dominate a teal"
    assert_in_delta 203.0 / 234.0, b.to_f / g, 0.05,
                    "#{ink} has lost the teal's blue/green balance — this is no longer the " \
                    "same hue, just a dark colour"
  end

  test "the default palette's CSS fallback matches what the derivation produces" do
    # The default palette emits NO variables at all (default? short-circuits
    # brand_palette_style_attr), so the stylesheet's own fallback is what every
    # unbranded Verto actually renders. If the two drift, the default look stops
    # matching the rule that is supposed to describe it.
    derived = BrandPalette.resolve(BrandPalette::DEFAULT)["primary_ink"].downcase
    css = File.read(Rails.root.join("app/assets/tailwind/application.css"))
    fallbacks = css.scan(/var\(--brand-primary-ink,\s*(#[0-9a-fA-F]{6})\)/).flatten.map(&:downcase)

    assert_operator fallbacks.size, :>=, 2,
                    "expected the selected-label rules to carry a --brand-primary-ink fallback"
    fallbacks.uniq.each do |fallback|
      assert_equal derived, fallback,
                   "the stylesheet falls back to #{fallback} but the derivation gives " \
                   "#{derived} for the default palette — an unbranded Verto would render a " \
                   "colour no code path chose"
    end
  end
end
