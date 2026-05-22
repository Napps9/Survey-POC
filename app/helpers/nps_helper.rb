module NpsHelper
  NPS_STATES = 5

  def nps_card?(card)
    card["type"].to_s == "nps"
  end

  # RIGHT-panel interactive control asset (the slider itself, e.g. a
  # thermometer). Defaults to a built-in thermometer.
  def nps_control_spec(card)
    nv  = card["nps_visual"]
    raw = nv.is_a?(Hash) ? (nv["control"] || (nv["mode"] ? nv : nil)) : nil
    resolve_nps_spec(raw, nps_fallback_control)
  end

  # LEFT-panel reactive asset (e.g. a sun with a facial expression) that reacts
  # to the slider position. Defaults to a built-in expressive sun face.
  def nps_reaction_spec(card)
    raw = card["nps_visual"].is_a?(Hash) ? card["nps_visual"]["reaction"] : nil
    resolve_nps_spec(raw, nps_fallback_reaction)
  end

  # Resolve + sanitize one visual spec (fill or states), falling back when the
  # stored spec is missing/unusable. Every SVG string is sanitized here.
  def resolve_nps_spec(raw, fallback)
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

  # Render one stage (<div.nps-visual> with the <svg>). The nps_slider controller
  # drives --nps-fill / --nps-hue and toggles .nps-state on both stages.
  def render_nps_stage(spec)
    vb = ERB::Util.h(spec["viewbox"])

    inner =
      if spec["mode"] == "fill"
        cid = "nps-clip-#{SecureRandom.hex(4)}"
        %(<defs>#{spec["defs"]}<clipPath id="#{cid}">#{spec["clip"]}</clipPath></defs>) +
          spec["back"].to_s +
          %(<g clip-path="url(##{cid})"><rect class="nps-liquid" x="0" y="0" ) +
          %(width="100%" height="100%" fill="#{ERB::Util.h(spec["liquid_color"])}"></rect></g>) +
          spec["front"].to_s
      else
        states  = spec["states"]
        initial = states.length / 2
        %(<defs>#{spec["defs"]}</defs>) +
          states.each_with_index.map do |st, i|
            active = i == initial ? " is-active" : ""
            %(<g class="nps-state#{active}" data-state="#{i}">#{st["svg"]}</g>)
          end.join
      end

    svg = %(<svg class="nps-svg" viewBox="#{vb}" preserveAspectRatio="xMidYMid meet" aria-hidden="true">#{inner}</svg>)
    content_tag(:div, svg.html_safe, class: "nps-visual", style: "--nps-hue:60;--nps-fill:0.5;")
  end

  # Permit only simple paint values; reject url()/scripty content. Falls back to
  # a hue-driven default so the colour tweens with sentiment.
  def nps_safe_color(color)
    c = color.to_s.strip
    default = "hsl(var(--nps-hue,140) 78% 52%)"
    return default if c.empty?
    safe = c.match?(/\A[#a-z0-9(),.%\s_-]+\z/i) &&
           !c.downcase.include?("url(") &&
           !c.downcase.include?("javascript")
    safe ? c : default
  end

  # Built-in RIGHT control: a thermometer that fills as you drag (bulb always
  # holds a little liquid). Colour tweens red->green via --nps-hue.
  def nps_fallback_control
    {
      "mode" => "fill",
      "viewbox" => "0 0 200 200",
      "liquid_color" => "hsl(var(--nps-hue,8) 85% 52%)",
      "defs" => "",
      "back" => %(<rect x="22" y="16" width="156" height="168" rx="26" fill="rgba(0,0,0,0.05)"/>) +
                %(<circle cx="100" cy="158" r="21" fill="hsl(var(--nps-hue,8) 85% 52%)"/>),
      "clip" => %(<rect x="90" y="30" width="20" height="120" rx="10"/><circle cx="100" cy="158" r="22"/>),
      "front" => %(<rect x="86" y="26" width="28" height="128" rx="14" fill="none" stroke="#9aa3b8" stroke-width="5"/>) +
                 %(<circle cx="100" cy="158" r="26" fill="none" stroke="#9aa3b8" stroke-width="5"/>) +
                 [44, 68, 92, 116].map { |y| %(<line x1="118" y1="#{y}" x2="130" y2="#{y}" stroke="#b9c0d0" stroke-width="3" stroke-linecap="round"/>) }.join
    }
  end

  # Built-in LEFT reaction: a sun whose face goes frown->smile and whose colour
  # tweens red->green with --nps-hue, based on the slider position.
  def nps_fallback_reaction
    mouths = [
      "M74 132 Q100 110 126 132",  # frown
      "M74 129 Q100 120 126 129",  # slight frown
      "M76 126 L124 126",          # flat
      "M74 124 Q100 142 126 124",  # smile
      "M72 121 Q100 153 128 121"   # big smile
    ]
    labels = %w[Awful Poor Okay Good Great]
    rays = (0...8).map do |i|
      %(<line x1="100" y1="36" x2="100" y2="20" stroke="hsl(var(--nps-hue,60) 85% 56%)" stroke-width="7" stroke-linecap="round" transform="rotate(#{i * 45} 100 100)"/>)
    end.join
    states = mouths.each_with_index.map do |d, i|
      svg = rays +
            %(<circle cx="100" cy="100" r="52" fill="hsl(var(--nps-hue,60) 85% 58%)"/>) +
            %(<circle cx="83" cy="92" r="7" fill="#1b2440"/>) +
            %(<circle cx="117" cy="92" r="7" fill="#1b2440"/>) +
            %(<path d="#{d}" fill="none" stroke="#1b2440" stroke-width="6" stroke-linecap="round"/>)
      { "label" => labels[i], "svg" => svg }
    end
    { "mode" => "states", "viewbox" => "0 0 200 200", "defs" => "", "states" => states }
  end
end
