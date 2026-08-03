# Canonical brand-palette logic shared by the models, the controller and the
# view helper. A palette is the four user-set roles (primary / cta / bg /
# panel); everything else (readable text, hover, surfaces) is derived so the
# Verto experience stays legible whatever colours a user picks.
#
# The JS mirror in app/javascript/lib/brand_palette.js must stay in sync with
# the maths here so the live preview matches the server render.
module BrandPalette
  # Matches today's Playverto look, so an unset palette renders unchanged.
  # "panel" is the card's left media panel; its default is the legacy literal
  # the CSS has always fallen back to.
  DEFAULT = { "primary" => "#01EACB", "cta" => "#01EACB", "bg" => "#1C2034", "panel" => "#2E3564" }.freeze
  ROLES   = %w[primary cta bg panel].freeze
  HEX     = /\A#[0-9a-fA-F]{6}\z/

  module_function

  def valid_hex?(value)
    value.is_a?(String) && value.strip.match?(HEX)
  end

  # Keep only the known roles, only when they are valid 6-digit hex. Returns a
  # hash of whatever survived (may be empty).
  def sanitize(raw)
    return {} unless raw.respond_to?(:[])
    ROLES.each_with_object({}) do |role, out|
      v = raw[role] || raw[role.to_sym]
      out[role] = "#" + v.strip.delete_prefix("#").downcase if valid_hex?(v)
    end
  end

  # True when the palette is absent or equal to the Playverto default, so
  # callers can skip injecting variables and let the CSS fallbacks render the
  # current look unchanged. Compared role-by-role with the default filling the
  # gaps (matching JS isDefault), so a legacy palette that stored the old
  # three-role default explicitly still counts as default after new roles are
  # added — otherwise every such Verto would repaint the day a role ships.
  def default?(raw)
    s = sanitize(raw)
    d = sanitize(DEFAULT)
    ROLES.all? { |role| (s[role] || d[role]) == d[role] }
  end

  # Full hash including derived keys, ready to spread into CSS variables.
  # "panel" is special-cased: when not explicitly set it follows the picked
  # background exactly — the panel showing a colour nobody chose (the old
  # lighten(bg, 13%) derivation) is the bug that made it a role.
  def resolve(raw)
    s = sanitize(raw)
    p = DEFAULT.merge(s)
    p["panel"] = s["panel"] || s["bg"] || DEFAULT["panel"]
    p.merge(
      "cta_text"     => contrast_text(p["cta"]),
      "cta_hover"    => darken(p["cta"], 0.12),
      "text"         => contrast_text(p["bg"]),
      "surface"      => lighten(p["bg"], 0.08),
      "surface_2"    => lighten(p["bg"], 0.13),
      "primary_soft" => rgba(p["primary"], 0.12)
    )
  end

  # --- colour maths ---------------------------------------------------------

  def rgb(hex)
    h = hex.to_s.delete_prefix("#")
    [ h[0, 2], h[2, 2], h[4, 2] ].map { |c| c.to_i(16) }
  end

  def to_hex(triplet)
    "#" + triplet.map { |c| format("%02X", c.clamp(0, 255).round) }.join
  end

  # WCAG relative luminance (0 = black, 1 = white).
  def luminance(hex)
    lin = rgb(hex).map do |c|
      c /= 255.0
      c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055)**2.4)
    end
    (0.2126 * lin[0]) + (0.7152 * lin[1]) + (0.0722 * lin[2])
  end

  # Readable foreground for a given background — picks whichever of dark/white
  # has the higher WCAG contrast ratio against the colour.
  def contrast_text(hex)
    l = luminance(hex)
    contrast_white = 1.05 / (l + 0.05)
    contrast_dark  = (l + 0.05) / 0.05
    contrast_dark >= contrast_white ? "#1C2034" : "#FFFFFF"
  end

  def darken(hex, amount)
    to_hex(rgb(hex).map { |c| c * (1 - amount) })
  end

  def lighten(hex, amount)
    to_hex(rgb(hex).map { |c| c + ((255 - c) * amount) })
  end

  def rgba(hex, alpha)
    r, g, b = rgb(hex)
    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end
end
