module NpsHelper
  # NPS is the classic 0–10 likelihood scale (the default), rendered as a
  # vertical "liquid container" the respondent drags to fill to their number.
  # The label set is editable, so a creator can use the traditional 0–10, a
  # shorter 4/5-point scale, or an agree/emotion range instead — the number of
  # steps follows the labels. NPS_STEPS is just the DEFAULT label count.
  NPS_STEPS = 11

  # The reactive Lottie animation (now used by the RANGE card, not NPS) has 5
  # frames; the range slider maps its position proportionally onto these. Kept
  # separate from NPS_STEPS so the two move independently.
  NPS_FRAMES = 5
  NPS_THEME  = "basketball".freeze # default reaction theme when a card doesn't pick one

  # Every selectable reaction-animation theme. Each is a folder
  # app/assets/lottie/<slug>/ holding 1..5.json (the five slider states). To add
  # a set: drop the folder in and add its slug here. NPS_THEME must be one of
  # these; Survey.sanitize_cards_images! whitelists a card's range_theme against
  # this list.
  RANGE_THEMES = %w[basketball football football_goal stopwatch
                    sun flowers recycling balance pizza radar calendar].freeze

  def nps_card?(card)
    card["type"].to_s == "nps"
  end

  # Default 0–10 labels when a card hasn't set its own.
  def nps_default_labels
    (0..(NPS_STEPS - 1)).map(&:to_s)
  end

  # Asset URLs for the 5 reaction Lotties. Files live under
  # `app/assets/lottie/<theme>/` which Sprockets treats as an asset path root,
  # so files resolve at `/assets/<theme>/<file>`. Using asset_path so digested
  # URLs work in prod.
  def nps_lottie_urls(theme = NPS_THEME)
    theme = NPS_THEME unless RANGE_THEMES.include?(theme.to_s)
    (1..NPS_FRAMES).map { |i| asset_path("#{theme}/#{i}.json") }
  end

  # The reaction theme a range card actually uses: its own `range_theme` when
  # that's a known slug, otherwise the default. Safe on any card hash.
  def range_theme_slug(card)
    slug = card.is_a?(Hash) ? card["range_theme"].to_s : ""
    RANGE_THEMES.include?(slug) ? slug : NPS_THEME
  end

  # [[label, slug], …] for the range card's editor theme <select>.
  def range_theme_options
    RANGE_THEMES.map { |slug| [ slug.titleize, slug ] }
  end

  # Editor payload for the theme picker: the control label plus, per theme, its
  # slug, display label and 5 asset URLs — so the editor can swap the live
  # preview (and build the picker on a type-switch) without a round-trip.
  # Emitted as JSON in the editor head (see surveys/show).
  def range_theme_picker_data
    {
      label:  t("editor.animation_theme", default: "Animation"),
      themes: RANGE_THEMES.map { |slug| { slug: slug, label: slug.titleize, urls: nps_lottie_urls(slug) } }
    }
  end

  # LEFT panel: a div that the lottie-player Stimulus controller mounts into.
  # The full list of Lottie URLs is passed via data attribute so the JS doesn't
  # need to know about Rails asset digesting.
  def render_nps_reaction(initial_value: 1, theme: NPS_THEME)
    content_tag :div, class: "nps-lottie",
                data: {
                  controller:                   "lottie-player",
                  "lottie-player-urls-value":   nps_lottie_urls(theme).to_json,
                  "lottie-player-current-value": initial_value
                } do
      content_tag(:div, "", class: "nps-lottie-mount",
                  data: { "lottie-player-target" => "mount" })
    end
  end

  # RIGHT panel: the vertical "liquid container", drawn as an SVG vessel themed
  # per Verto. Each vessel is a real object silhouette (test tube, flask, mug…)
  # with its own width so it reads as the thing it is. One <svg> carries: the
  # grey "empty" fill, the rising teal liquid (surface waves + bubbles rising
  # up through it), and the black outline stroke on top, plus any extras (jar
  # lid, mug handle, popsicle stick). The liquid level follows --nps-fill (0..1,
  # set by nps_slider_controller) by translating the `.nps-liquid` group — that
  # rising/falling motion IS the drag feedback, so nothing else sits over the
  # vessel; the static label list to the left shows which value is selected
  # (highlighted).
  #
  # Each entry: w (viewBox width), cx/hw (bubble column centre + half-spread),
  # kind (extra: jar lid / mug handle / popsicle stick), path (the open-topped
  # body outline; also the fill clip when closed with Z).
  NPS_VESSELS = {
    "tube"     => { w: 68,  cx: 34, hw: 11, kind: nil,   path: "M20,16 L20,300 A14,14 0 0 0 48,300 L48,16" },
    "pill"     => { w: 78,  cx: 39, hw: 13, kind: nil,   path: "M24,54 Q24,24 39,24 Q54,24 54,54 L54,286 Q54,316 39,316 Q24,316 24,286 Z" },
    "can"      => { w: 92,  cx: 46, hw: 26, kind: nil,   path: "M16,52 Q16,36 46,36 Q76,36 76,52 L76,288 Q76,304 46,304 Q16,304 16,288 Z" },
    "bottle"   => { w: 96,  cx: 48, hw: 22, kind: nil,   path: "M40,18 L40,74 Q24,94 24,134 L24,296 Q24,306 32,306 L64,306 Q72,306 72,296 L72,134 Q72,94 56,74 L56,18" },
    "popsicle" => { w: 98,  cx: 49, hw: 26, kind: "pop", path: "M20,54 Q20,26 49,26 Q78,26 78,54 L78,258 Q78,268 68,268 L30,268 Q20,268 20,258 Z" },
    "glass"    => { w: 106, cx: 53, hw: 28, kind: nil,   path: "M18,24 L30,300 Q30,306 36,306 L70,306 Q76,306 76,300 L88,24" },
    "beaker"   => { w: 116, cx: 58, hw: 38, kind: nil,   path: "M18,44 L18,298 Q18,306 26,306 L90,306 Q98,306 98,298 L98,52 L110,40" },
    "jar"      => { w: 118, cx: 59, hw: 40, kind: "jar", path: "M18,64 L18,298 Q18,306 26,306 L92,306 Q100,306 100,298 L100,64 L94,50 L24,50 Z" },
    "flask"    => { w: 130, cx: 65, hw: 22, kind: nil,   path: "M54,22 L58,34 L58,90 L10,296 Q10,306 20,306 L110,306 Q120,306 120,296 L72,90 L72,34 L76,22" },
    "mug"      => { w: 132, cx: 54, hw: 34, kind: "mug", path: "M16,52 L16,300 Q16,308 24,308 L84,308 Q92,308 92,300 L92,52" }
  }.freeze

  def render_nps_control(shape: "pill", steps: NPS_STEPS)
    v = NPS_VESSELS.fetch(shape) { NPS_VESSELS.fetch("pill") }
    content_tag :div, class: "nps-control nps-shape-#{shape}",
                style: "--nps-aspect: #{v[:w]} / 340",
                data: { axis: "vertical" } do
      concat nps_vessel_svg(shape, v)
    end
  end

  # Builds the vessel <svg>. All geometry is internal (no user input; `shape` is
  # validated against NPS_VESSELS by the caller), so the string is html_safe.
  # Bubbles are seeded off the shape name so the markup is stable per shape.
  def nps_vessel_svg(shape, v)
    w   = v[:w]
    rng = Random.new(Digest::SHA256.hexdigest(shape)[0, 8].to_i(16))
    wave = ->(y) { "M-40,#{y} q32.5,-8 65,0 t65,0 t65,0 t65,0 t65,0 L290,430 L-40,430 Z" }
    extras = {
      "jar" => %(<rect x="22" y="22" width="74" height="26" rx="8" fill="#dfe2ee" stroke="#1a1a1a" stroke-width="6"/>),
      "mug" => %(<path d="M92,116 C130,120 130,244 92,248" fill="none" stroke="#1a1a1a" stroke-width="13" stroke-linecap="round"/>),
      "pop" => %(<rect x="41" y="260" width="16" height="52" rx="6" fill="#c9a678" stroke="#1a1a1a" stroke-width="4"/>)
    }[v[:kind]].to_s

    <<~SVG.html_safe
      <svg class="nps-vessel" viewBox="0 0 #{w} 340" preserveAspectRatio="xMidYMid meet" aria-hidden="true" focusable="false">
        <defs>
          <linearGradient id="nps-g-#{shape}" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" style="stop-color: var(--brand-primary, #16e0c4)"/>
            <stop offset="1" style="stop-color: var(--brand-primary, #01c9ad); stop-opacity: .85"/>
          </linearGradient>
          <clipPath id="nps-c-#{shape}"><path d="#{v[:path]} Z"/></clipPath>
        </defs>
        <g clip-path="url(#nps-c-#{shape})">
          <rect x="-40" y="0" width="#{w + 80}" height="340" fill="#eef0f6"/>
          <g class="nps-liquid">
            <g class="nps-surface">
              <path class="nps-wave2" d="#{wave.call(3)}" fill="url(#nps-g-#{shape})"/>
              <path class="nps-wave"  d="#{wave.call(0)}" fill="url(#nps-g-#{shape})"/>
            </g>
            <rect x="-40" y="4" width="#{w + 80}" height="440" fill="url(#nps-g-#{shape})"/>
            #{nps_bubbles(v[:cx], v[:hw], rng)}
          </g>
        </g>
        <path d="#{v[:path]}" fill="none" stroke="#1a1a1a" stroke-width="6" stroke-linejoin="round" stroke-linecap="round"/>
        #{extras}
      </svg>
    SVG
  end

  # Nine bubbles rising up through the liquid. Each carries its own rise/sway/
  # duration/delay so they read as an uneven stream. They live INSIDE the
  # translated `.nps-liquid` group, so they only ever appear within the fluid.
  def nps_bubbles(cx, hw, rng)
    Array.new(9) do
      x     = cx + (rng.rand * 2 - 1) * hw * 0.6
      r     = 1.8 + rng.rand * 2.2
      start = 150 + rng.rand * 85
      rise  = -(start - (10 + rng.rand * 8))
      sway  = rng.rand * 8 - 4
      dur   = 1.9 + rng.rand * 1.5
      delay = rng.rand * 2.6
      %(<circle cx="#{x.round(1)}" cy="#{start.round}" r="#{r.round(1)}" fill="#ecfffb" class="nps-bub" ) +
        %(style="--rise: #{rise.round}px; --sway: #{sway.round(1)}px; --dur: #{dur.round(2)}s; --d: #{delay.round(2)}s"/>)
    end.join.html_safe
  end
end
