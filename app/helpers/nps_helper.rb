module NpsHelper
  NPS_STATES = 5

  def nps_card?(card)
    card["type"].to_s == "nps"
  end

  # ---------- RIGHT: the themed slider control (must have a draggable handle) ----------

  def nps_control_spec(card)
    nv  = card["nps_visual"]
    raw = nv.is_a?(Hash) ? nv["control"] : nil
    resolve_nps_control(raw, nps_fallback_control)
  end

  def resolve_nps_control(raw, fallback)
    usable = raw.is_a?(Hash) && (raw["fill_clip"].present? || raw["front"].present? || raw["back"].present?)
    spec = usable ? raw : fallback
    {
      "axis"       => (spec["axis"] == "horizontal" ? "horizontal" : "vertical"),
      "viewbox"    => spec["viewbox"].presence || "0 0 200 200",
      "defs"       => SvgSanitizer.clean(spec["defs"].to_s),
      "fill_clip"  => SvgSanitizer.clean(spec["fill_clip"].to_s),
      "fill_color" => nps_safe_color(spec["fill_color"]),
      "back"       => SvgSanitizer.clean(spec["back"].to_s),
      "front"      => SvgSanitizer.clean(spec["front"].to_s),
      "thumb"      => SvgSanitizer.clean(spec["thumb"].to_s).presence || nps_default_thumb
    }
  end

  # Renders the interactive slider: optional liquid fill clipped to the vessel,
  # the skin, and a `.nps-thumb` handle the controller translates along the axis.
  def render_nps_control(spec)
    vb   = ERB::Util.h(spec["viewbox"])
    axis = spec["axis"]
    cid  = "nps-clip-#{SecureRandom.hex(4)}"

    fill =
      if spec["fill_clip"].present?
        %(<defs>#{spec["defs"]}<clipPath id="#{cid}">#{spec["fill_clip"]}</clipPath></defs>#{spec["back"]}) +
          %(<g clip-path="url(##{cid})"><rect class="nps-liquid" data-axis="#{axis}" x="0" y="0" ) +
          %(width="100%" height="100%" fill="#{ERB::Util.h(spec["fill_color"])}"></rect></g>)
      else
        %(<defs>#{spec["defs"]}</defs>#{spec["back"]})
      end

    svg = %(<svg class="nps-svg" viewBox="#{vb}" preserveAspectRatio="xMidYMid meet" aria-hidden="true">) +
          fill + spec["front"].to_s +
          %(<g class="nps-thumb">#{spec["thumb"]}</g></svg>)

    content_tag(:div, svg.html_safe, class: "nps-visual nps-control",
                data: { axis: axis }, style: "--nps-hue:60;--nps-fill:0.5;")
  end

  # ---------- LEFT: a fixed face template; Claude only supplies a themed accent ----------

  # The mouth morphs frown -> smile across the value range (sized for an r=54 head).
  NPS_MOUTHS = [
    "M76 130 Q100 110 124 130",  # frown
    "M76 127 Q100 119 124 127",  # slight frown
    "M78 124 L122 124",          # flat
    "M76 122 Q100 138 124 122",  # smile
    "M74 119 Q100 150 126 119"   # big smile
  ].freeze

  def nps_reaction_spec(card)
    nv     = card["nps_visual"]
    accent = (nv.is_a?(Hash) && nv["reaction"].is_a?(Hash)) ? nv["reaction"]["accent"].to_s : ""
    accent = SvgSanitizer.clean(accent)
    { "accent" => accent.presence || nps_fallback_reaction["accent"] }
  end

  # The app draws a consistent face (head + eyes + a mouth that morphs sad->happy,
  # coloured by --nps-hue). The themed `accent` is drawn behind it. The controller
  # toggles the active mouth (.nps-state) and sets --nps-hue from the slider.
  def render_nps_reaction(spec)
    initial = NPS_MOUTHS.length / 2
    base = spec["accent"].to_s +
           %(<circle cx="100" cy="100" r="54" fill="hsl(var(--nps-hue,60) 85% 58%)"/>) +
           %(<circle cx="82" cy="92" r="7.5" fill="#1b2440"/><circle cx="118" cy="92" r="7.5" fill="#1b2440"/>)
    mouths = NPS_MOUTHS.each_with_index.map do |d, i|
      %(<g class="nps-state#{i == initial ? ' is-active' : ''}" data-state="#{i}">) +
        %(<path d="#{d}" fill="none" stroke="#1b2440" stroke-width="6" stroke-linecap="round"/></g>)
    end.join
    svg = %(<svg class="nps-svg" viewBox="0 0 200 200" preserveAspectRatio="xMidYMid meet" aria-hidden="true">#{base}#{mouths}</svg>)
    content_tag(:div, svg.html_safe, class: "nps-visual", style: "--nps-hue:60;")
  end

  # ---------- shared ----------

  def nps_safe_color(color)
    c = color.to_s.strip
    default = "hsl(var(--nps-hue,140) 78% 52%)"
    return default if c.empty?
    safe = c.match?(/\A[#a-z0-9(),.%\s_-]+\z/i) &&
           !c.downcase.include?("url(") &&
           !c.downcase.include?("javascript")
    safe ? c : default
  end

  # A neutral draggable knob, authored around the origin; the controller
  # translates it along the axis.
  def nps_default_thumb
    %(<circle r="13" fill="#ffffff" stroke="var(--brand-primary,#7C4DFF)" stroke-width="4"/>) +
      %(<circle r="4" fill="var(--brand-primary,#7C4DFF)"/>)
  end

  # Built-in control: a vertical thermometer slider with a level handle.
  def nps_fallback_control
    {
      "axis" => "vertical", "viewbox" => "0 0 200 200",
      "fill_color" => "hsl(var(--nps-hue,8) 85% 52%)", "defs" => "",
      "fill_clip" => %(<rect x="90" y="30" width="20" height="120" rx="10"/><circle cx="100" cy="158" r="22"/>),
      "back" => %(<rect x="22" y="16" width="156" height="168" rx="26" fill="rgba(0,0,0,0.05)"/>) +
                %(<circle cx="100" cy="158" r="21" fill="hsl(var(--nps-hue,8) 85% 52%)"/>),
      "front" => %(<rect x="86" y="26" width="28" height="128" rx="14" fill="none" stroke="#9aa3b8" stroke-width="5"/>) +
                 %(<circle cx="100" cy="158" r="26" fill="none" stroke="#9aa3b8" stroke-width="5"/>) +
                 [44, 68, 92, 116].map { |y| %(<line x1="118" y1="#{y}" x2="130" y2="#{y}" stroke="#b9c0d0" stroke-width="3" stroke-linecap="round"/>) }.join,
      "thumb" => %(<rect x="-21" y="-7" width="42" height="14" rx="7" fill="#ffffff" stroke="#9aa3b8" stroke-width="2.5"/>) +
                 %(<line x1="-6" y1="0" x2="6" y2="0" stroke="#9aa3b8" stroke-width="2"/>)
    }
  end

  # Built-in accent: a ring of sun rays around the face (tweens with --nps-hue).
  def nps_fallback_reaction
    rays = (0...8).map do |i|
      %(<line x1="100" y1="34" x2="100" y2="18" stroke="hsl(var(--nps-hue,60) 85% 56%)" stroke-width="7" stroke-linecap="round" transform="rotate(#{i * 45} 100 100)"/>)
    end.join
    { "accent" => rays }
  end
end
