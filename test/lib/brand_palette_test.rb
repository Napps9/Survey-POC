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
end
