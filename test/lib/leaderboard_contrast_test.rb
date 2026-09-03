require "test_helper"

# The leaderboard's colours, held to WCAG AA (4.5:1 for its text — nothing on
# the board qualifies as "large text", and 3:1 for the card boundary). The
# ratios are computed from the CSS source over the real background stack, so a
# colour tweak that quietly drops below the floor fails here with a number
# rather than shipping as an unreadable board.
#
# The stack being audited: the thank-you card is a FIXED #1C2034 (deliberately
# palette-independent — see the comment on .preview-thankyou-card), and the
# board tints it with 12% of the brand primary. Alpha-white text is blended
# over that tint before measuring. Default-palette fallbacks are what's
# audited; --brand-cta-text is exempt because BrandPalette.contrast_text
# derives it per palette with this same maths.
class LeaderboardContrastTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/tailwind/application.css").freeze

  def css
    @css ||= File.read(CSS)
  end

  def rule_body(selector)
    body = css[/#{Regexp.escape(selector)}\s*\{([^}]*)\}/m, 1]
    assert body, "#{selector} rule is gone from application.css"
    body
  end

  # First colour literal (hex or rgba) in a declaration like "color: ...".
  def declared(selector, property)
    value = rule_body(selector)[/#{property}:\s*([^;]+);/m, 1]
    assert value, "#{selector} no longer declares #{property}"
    value.strip
  end

  # ── colour maths (same WCAG formulae as BrandPalette) ──────────────────────

  def rgb(color)
    if (m = color.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/))
      m.captures.map(&:to_i)
    elsif (m = color.match(/#(\h{2})(\h{2})(\h{2})\b/))
      m.captures.map { |c| c.to_i(16) }
    elsif (m = color.match(/#(\h)(\h)(\h)\b/))
      m.captures.map { |c| (c * 2).to_i(16) }
    else
      flunk "can't parse colour literal #{color.inspect}"
    end
  end

  def alpha(color)
    color[/rgba\([^)]*,\s*(0?\.\d+|1|0)\s*\)/, 1]&.to_f || 1.0
  end

  def blend(fg_color, bg_triplet)
    a = alpha(fg_color)
    rgb(fg_color).zip(bg_triplet).map { |f, b| ((a * f) + ((1 - a) * b)).round }
  end

  def luminance(triplet)
    lin = triplet.map do |c|
      c /= 255.0
      c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4)
    end
    (0.2126 * lin[0]) + (0.7152 * lin[1]) + (0.0722 * lin[2])
  end

  def contrast(fg_triplet, bg_triplet)
    l = [ luminance(fg_triplet), luminance(bg_triplet) ]
    ((l.max + 0.05) / (l.min + 0.05)).round(2)
  end

  # The board's background: the fixed thank-you card colour with the
  # default-palette 12% primary tint composited on top.
  def board_bg
    @board_bg ||= begin
      card = rgb(declared(".preview-thankyou-card", "background"))
      blend(declared(".leaderboard-card", "background")[/rgba\([^)]*\)/] || "rgba(1,234,203,0.12)", card)
    end
  end

  def assert_contrast(fg_color, bg_triplet, floor, label)
    effective = blend(fg_color, bg_triplet)
    ratio = contrast(effective, bg_triplet)
    assert ratio >= floor,
           "#{label}: #{fg_color} measures #{ratio}:1 against its background — " \
           "below the #{floor}:1 floor. Raise the colour, don't ship it dimmer."
  end

  test "every text colour on the board clears 4.5:1 on the tinted card" do
    {
      ".leaderboard-title" => "colour-accent title",
      ".leaderboard-rank"  => "rank numeral (the smallest text on the board)",
      ".leaderboard-name"  => "player name",
      ".leaderboard-total" => "token total",
      ".leaderboard-breakdown" => "per-type breakdown under the name",
      ".leaderboard-self"  => "\"you played as\" line",
      ".leaderboard-note"  => "queued/empty note",
      ".leaderboard-gap"   => "gap marker above your appended row"
    }.each do |selector, label|
      assert_contrast declared(selector, "color"), board_bg, 4.5, label
    end
  end

  test "the highlighted row keeps its text readable and its boundary visible" do
    you_bg = blend(declared(".leaderboard-row.is-you", "background")[/rgba\([^)]*\)/] || "rgba(1,234,203,0.16)", board_bg)
    assert_contrast declared(".leaderboard-name", "color"), you_bg, 4.5, "name on the is-you row"
    # The row's border is a UI boundary, not text — WCAG 1.4.11's 3:1.
    border_colour = declared(".leaderboard-row.is-you", "border")[/#\h{6}|rgba\([^)]*\)/]
    assert border_colour, ".leaderboard-row.is-you border no longer names a colour"
    assert_contrast border_colour, you_bg, 3.0, "is-you row boundary"
  end

  test "the you-badge fallbacks clear 4.5:1 (non-default palettes are covered by contrast_text)" do
    badge_bg = rgb(declared(".leaderboard-you-badge", "background")[/#\h{6}/] || "#01EACB")
    badge_fg = declared(".leaderboard-you-badge", "color")[/#\h{6}/]
    assert badge_fg, ".leaderboard-you-badge no longer carries a hex fallback for its text"
    assert_contrast badge_fg, badge_bg, 4.5, "You badge"
  end

  test "the intro teaser inherits the note colour instead of painting brand primary on a light pill" do
    tease_rules = css.scan(/\.leaderboard-tease[^{]*\{([^}]*)\}/m).flatten
    assert tease_rules.none? { |b| b.match?(/color:/) },
           ".leaderboard-tease declares its own colour again. Brand primary on the near-white " \
           "intro pill measured 1.45:1 for the default palette — the teaser must inherit " \
           ".welcome-intake-tokens-note. If emphasis is needed, use weight, not colour."

    # And the inherited pair itself: the note's amber on its pill over a white card.
    pill_bg = blend(declared(".welcome-intake-tokens-note", "background")[/rgba\([^)]*\)/], [ 255, 255, 255 ])
    assert_contrast declared(".welcome-intake-tokens-note", "color"), pill_bg, 4.5, "token-intro note (teaser inherits this)"
  end
end
