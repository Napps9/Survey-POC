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

  # ---------- LEFT: a fixed expressive face template; Claude only supplies a themed accent ----------

  def nps_reaction_spec(card)
    nv     = card["nps_visual"]
    accent = (nv.is_a?(Hash) && nv["reaction"].is_a?(Hash)) ? nv["reaction"]["accent"].to_s : ""
    accent = SvgSanitizer.clean(accent)
    { "accent" => accent.presence || nps_fallback_reaction["accent"] }
  end

  # The app draws a glossy character face (à la the source Lottie sun): a
  # sentiment-coloured sphere with a sheen, thick curved brows, white eyes with
  # pupils, and a mouth that morphs frown -> open toothy grin. The themed `accent`
  # (e.g. rays) sits behind it. The controller toggles the active expression
  # (.nps-state) and sets --nps-hue from the slider.
  def render_nps_reaction(spec)
    hid     = "npssheen-#{SecureRandom.hex(4)}"
    layers  = nps_face_layers
    initial = layers.length / 2
    base =
      %(<defs><radialGradient id="#{hid}" cx="38%" cy="30%" r="68%">) +
      %(<stop offset="0" stop-color="rgba(255,255,255,0.55)"/>) +
      %(<stop offset="62%" stop-color="rgba(255,255,255,0)"/></radialGradient></defs>) +
      spec["accent"].to_s +
      %(<circle cx="100" cy="100" r="54" fill="hsl(var(--nps-hue,60) 85% 55%)"/>) +
      %(<circle cx="100" cy="100" r="54" fill="url(##{hid})"/>) +
      %(<ellipse cx="127" cy="84" rx="11" ry="24" fill="rgba(255,255,255,0.30)" transform="rotate(20 127 84)"/>) +
      %(<ellipse cx="85" cy="93" rx="14" ry="16.5" fill="#ffffff"/><ellipse cx="115" cy="93" rx="14" ry="16.5" fill="#ffffff"/>) +
      %(<circle cx="87" cy="90" r="6.5" fill="#1a1a1a"/><circle cx="113" cy="90" r="6.5" fill="#1a1a1a"/>)
    states = layers.each_with_index.map do |inner, i|
      %(<g class="nps-state#{i == initial ? ' is-active' : ''}" data-state="#{i}">#{inner}</g>)
    end.join
    svg = %(<svg class="nps-svg" viewBox="0 0 200 200" preserveAspectRatio="xMidYMid meet" aria-hidden="true">#{base}#{states}</svg>)
    content_tag(:div, svg.html_safe, class: "nps-visual", style: "--nps-hue:60;")
  end

  # Five expressions (low->high): thick brows + cheeks + mouth, the top one an
  # open toothy grin.
  def nps_face_layers
    brows = [
      %(<path d="M66 74 L93 87"/><path d="M134 74 L107 87"/>),
      %(<path d="M67 84 Q80 79 93 83"/><path d="M133 84 Q120 79 107 83"/>),
      %(<path d="M68 81 Q80 78 93 81"/><path d="M132 81 Q120 78 107 81"/>),
      %(<path d="M66 83 Q80 71 94 78"/><path d="M134 83 Q120 71 106 78"/>),
      %(<path d="M63 81 Q82 63 99 75"/><path d="M137 81 Q118 63 101 75"/>)
    ].map { |b| %(<g fill="none" stroke="#1a1a1a" stroke-width="7" stroke-linecap="round" stroke-linejoin="round">#{b}</g>) }
    mouths = [
      %(<path d="M76 137 Q100 114 124 137" fill="none" stroke="#1a1a1a" stroke-width="7" stroke-linecap="round"/>),
      %(<path d="M80 131 Q100 123 120 131" fill="none" stroke="#1a1a1a" stroke-width="7" stroke-linecap="round"/>),
      %(<path d="M82 127 L118 127" fill="none" stroke="#1a1a1a" stroke-width="7" stroke-linecap="round"/>),
      %(<path d="M76 125 Q100 145 124 125" fill="none" stroke="#1a1a1a" stroke-width="7" stroke-linecap="round"/>),
      %(<path d="M70 117 Q100 129 130 117 Q124 152 100 154 Q76 152 70 117 Z" fill="#ffffff" stroke="#1a1a1a" stroke-width="4.5" stroke-linejoin="round"/>) +
        %(<path d="M74 121 Q100 131 126 121" fill="none" stroke="#1a1a1a" stroke-width="3"/>) +
        %(<g stroke="#1a1a1a" stroke-width="3" stroke-linecap="round"><line x1="100" y1="122" x2="100" y2="153"/><line x1="87" y1="121" x2="84" y2="150"/><line x1="113" y1="121" x2="116" y2="150"/></g>)
    ]
    cheeks = ["", "", "",
      %(<circle cx="64" cy="120" r="8" fill="rgba(255,110,120,0.30)"/><circle cx="136" cy="120" r="8" fill="rgba(255,110,120,0.30)"/>),
      %(<circle cx="62" cy="120" r="9" fill="rgba(255,110,120,0.45)"/><circle cx="138" cy="120" r="9" fill="rgba(255,110,120,0.45)"/>)]
    (0..4).map { |i| cheeks[i] + brows[i] + mouths[i] }
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

  # Built-in accent: a ring of triangular, two-tone sun rays behind the face.
  def nps_fallback_reaction
    rays = (0...12).map do |i|
      c = i.even? ? "#FBC02D" : "#F59E0B"
      %(<path d="M100 6 L112 50 L88 50 Z" fill="#{c}" transform="rotate(#{i * 30} 100 100)"/>)
    end.join
    { "accent" => rays }
  end
end
