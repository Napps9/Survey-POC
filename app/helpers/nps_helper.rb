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

  # ---------- LEFT: the reactive asset (states or fill) ----------

  def nps_reaction_spec(card)
    nv  = card["nps_visual"]
    raw = nv.is_a?(Hash) ? (nv["reaction"] || (nv["mode"] && !nv["control"] ? nv : nil)) : nil
    resolve_nps_reaction(raw, nps_fallback_reaction)
  end

  def resolve_nps_reaction(raw, fallback)
    usable = raw.is_a?(Hash) &&
             (raw["mode"] == "fill" ? raw["clip"].present? : Array(raw["states"]).any?)
    spec = usable ? raw : fallback
    mode = spec["mode"] == "fill" ? "fill" : "states"
    base = {
      "mode"    => mode,
      "viewbox" => spec["viewbox"].presence || "0 0 200 200",
      "defs"    => SvgSanitizer.clean(spec["defs"].to_s)
    }
    if mode == "fill"
      base.merge(
        "back"         => SvgSanitizer.clean(spec["back"].to_s),
        "clip"         => SvgSanitizer.clean(spec["clip"].to_s),
        "front"        => SvgSanitizer.clean(spec["front"].to_s),
        "liquid_color" => nps_safe_color(spec["liquid_color"])
      )
    else
      base.merge(
        "states" => Array(spec["states"]).first(NPS_STATES).map do |s|
          { "label" => s["label"].to_s, "svg" => SvgSanitizer.clean(s["svg"].to_s) }
        end
      )
    end
  end

  def render_nps_stage(spec)
    vb = ERB::Util.h(spec["viewbox"])
    inner =
      if spec["mode"] == "fill"
        cid = "nps-clip-#{SecureRandom.hex(4)}"
        %(<defs>#{spec["defs"]}<clipPath id="#{cid}">#{spec["clip"]}</clipPath></defs>#{spec["back"]}) +
          %(<g clip-path="url(##{cid})"><rect class="nps-liquid" data-axis="vertical" x="0" y="0" ) +
          %(width="100%" height="100%" fill="#{ERB::Util.h(spec["liquid_color"])}"></rect></g>#{spec["front"]})
      else
        states  = spec["states"]
        initial = states.length / 2
        %(<defs>#{spec["defs"]}</defs>) +
          states.each_with_index.map do |st, i|
            %(<g class="nps-state#{i == initial ? ' is-active' : ''}" data-state="#{i}">#{st["svg"]}</g>)
          end.join
      end
    svg = %(<svg class="nps-svg" viewBox="#{vb}" preserveAspectRatio="xMidYMid meet" aria-hidden="true">#{inner}</svg>)
    content_tag(:div, svg.html_safe, class: "nps-visual", style: "--nps-hue:60;--nps-fill:0.5;")
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

  # Built-in reaction: a sun whose face goes frown->smile, colour via --nps-hue.
  def nps_fallback_reaction
    mouths = [
      "M74 132 Q100 110 126 132", "M74 129 Q100 120 126 129", "M76 126 L124 126",
      "M74 124 Q100 142 126 124", "M72 121 Q100 153 128 121"
    ]
    labels = %w[Awful Poor Okay Good Great]
    rays = (0...8).map do |i|
      %(<line x1="100" y1="36" x2="100" y2="20" stroke="hsl(var(--nps-hue,60) 85% 56%)" stroke-width="7" stroke-linecap="round" transform="rotate(#{i * 45} 100 100)"/>)
    end.join
    states = mouths.each_with_index.map do |d, i|
      svg = rays +
            %(<circle cx="100" cy="100" r="52" fill="hsl(var(--nps-hue,60) 85% 58%)"/>) +
            %(<circle cx="83" cy="92" r="7" fill="#1b2440"/><circle cx="117" cy="92" r="7" fill="#1b2440"/>) +
            %(<path d="#{d}" fill="none" stroke="#1b2440" stroke-width="6" stroke-linecap="round"/>)
      { "label" => labels[i], "svg" => svg }
    end
    { "mode" => "states", "viewbox" => "0 0 200 200", "defs" => "", "states" => states }
  end
end
