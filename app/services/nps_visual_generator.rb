require "anthropic"

# Generates the two themed assets for an NPS card, in its OWN Claude call (not
# part of emit_survey, so the SVGs don't blow the survey-generation budget):
#   control  — the RIGHT asset that works AS A SLIDER (a draggable handle moves
#              along an axis; optional liquid fill). e.g. a thermometer.
#   reaction — the LEFT asset that reacts to the value (states or fill). e.g. a sun.
# Output is normalised + sanitised into the shape NpsHelper expects.
class NpsVisualGenerator
  MODEL      = "claude-sonnet-4-6"
  MAX_TOKENS = 8000

  CONTROL_PROPS = {
    axis:       { type: "string", enum: %w[vertical horizontal], description: "Drag axis: vertical for vessels (thermometer/cup), horizontal for a track+thumb." },
    viewbox:    { type: "string", description: "Square viewBox, e.g. '0 0 200 200'." },
    defs:       { type: "string", description: "Optional <defs> inner content." },
    fill_clip:  { type: "string", description: "Optional: the region that fills (vessel interior or track groove); the app scales the liquid within it by the value." },
    fill_color: { type: "string", description: "Fill colour. Prefer 'hsl(var(--nps-hue,140) 80% 50%)' to tween red→green, or a fixed on-theme colour." },
    back:       { type: "string", description: "SVG behind the fill (track/vessel body)." },
    front:      { type: "string", description: "SVG outline/details on top (use fill=\"none\" for outlines, ticks)." },
    thumb:      { type: "string", description: "The DRAGGABLE HANDLE, authored around origin (0,0), <=~44px. The app translates it along the axis. REQUIRED so it works as a slider." }
  }.freeze

  REACTION_PROPS = {
    mode:         { type: "string", enum: %w[states fill], description: "states = up to 5 cross-faded expressions; fill = a vessel that fills." },
    viewbox:      { type: "string", description: "Square viewBox." },
    defs:         { type: "string" },
    states:       { type: "array", minItems: 3, maxItems: 5,
                    description: "states mode: ordered low→high (5 preferred).",
                    items: { type: "object", properties: { label: { type: "string" }, svg: { type: "string" } }, required: %w[svg] } },
    clip:         { type: "string", description: "fill mode: vessel interior shape." },
    back:         { type: "string" },
    front:        { type: "string" },
    liquid_color: { type: "string" }
  }.freeze

  TOOL = {
    name: "emit_nps_visual",
    description: "Emit a themed slider control (right) + a reactive asset (left) for an NPS card.",
    input_schema: {
      type: "object",
      properties: {
        subject:  { type: "string", description: "Short theme tag, e.g. 'weather', 'coffee', 'fitness'." },
        control:  { type: "object", description: "RIGHT: the asset that works AS A SLIDER (draggable handle).", properties: CONTROL_PROPS, required: %w[axis viewbox thumb] },
        reaction: { type: "object", description: "LEFT: the asset that reacts to the slider value.", properties: REACTION_PROPS, required: %w[mode viewbox] }
      },
      required: %w[control reaction]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You design TWO small, iconic SVG assets for a Verto "NPS / reactive scale"
    question, themed to the survey's THEME, AUDIENCE and TONE.

    1) control — the RIGHT-hand asset. It MUST work as a slider: it has a visible
       DRAGGABLE HANDLE (`thumb`) that the respondent moves along an axis to set the
       value. NEVER a static expression-only icon.
       - axis: "vertical" for vessels you fill bottom→top (thermometer, cup, beaker,
         battery, rocket), "horizontal" for a track the handle slides left→right.
       - fill_clip + fill_color (optional): the app scales a liquid within fill_clip
         by the value, so the vessel fills as you drag. Prefer
         "hsl(var(--nps-hue,140) 80% 50%)" so it tweens, or a fixed on-theme colour.
       - back / front: the vessel/track skin (outlines with fill="none").
       - thumb: the handle, authored around the origin (0,0), <=~44px. The app
         translates it along the axis. Make it clearly a grabbable handle/marker.

    2) reaction — the LEFT-hand asset that REACTS to the value (no drag). Either
       "states" (up to 5 ordered low→high expressions the app cross-fades — e.g. a
       sun whose face goes sad→happy; use fill="hsl(var(--nps-hue,60) 82% 58%)" so it
       tweens), or "fill" (a vessel that fills like the control).

    Rules:
    - Square viewBox, default "0 0 200 200". Simple, iconic, centred; each SVG piece
      under ~1.5KB.
    - Brand colours allowed via var(--brand-primary), var(--brand-cta),
      var(--brand-text); hsl(var(--nps-hue) …) for sentiment.
    - Use ONLY these tags: g, path, circle, ellipse, rect, line, polyline, polygon,
      defs, linearGradient, radialGradient, stop, clipPath, use, title. Presentation
      attributes only.
    - NO <script>, <foreignObject>, <image>, <style>, event handlers (on*), external
      URLs, or href to anything but a local "#id".
    Output via the emit_nps_visual tool.
  PROMPT

  def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    @client = Anthropic::Client.new(api_key: api_key)
  end

  def call(theme:, audience_age:, key_insight:, question:, options: [], notes: nil, brand_palette: nil)
    palette = brand_palette.is_a?(Hash) ? brand_palette.slice("primary", "cta", "bg").to_json : "(default)"
    user_message = <<~MSG
      Survey theme: #{theme}
      Audience: #{audience_age}
      Key insight: #{key_insight}
      Tone / notes: #{notes.to_s.strip.presence || '(none)'}
      Brand colours: #{palette}

      The NPS question is: "#{question}"
      Scale labels (low → high): #{Array(options).join(' · ').presence || '0 … 10'}

      Design the control (right slider) + reaction (left) for THIS question, themed
      to fit. The control MUST have a draggable handle and work as a slider. Output
      via the emit_nps_visual tool.
    MSG

    response = @client.messages.create(
      model:       MODEL,
      max_tokens:  MAX_TOKENS,
      system:      SYSTEM,
      tools:       [ TOOL ],
      tool_choice: { type: "tool", name: "emit_nps_visual" },
      messages:    [ { role: "user", content: user_message } ]
    )

    block = Array(response.content).find { |b| tool_use?(b) }
    raise "Model did not return a tool_use block" unless block

    normalize(deep_stringify(input_of(block)))
  end

  # Sanitise + shape the raw tool input into a stored nps_visual ({control, reaction}).
  # Public so it can be unit-tested without an API call.
  def normalize(input)
    { "subject"  => input["subject"].to_s,
      "control"  => normalize_control(input["control"]),
      "reaction" => normalize_reaction(input["reaction"]) }
  end

  private

  def normalize_control(c)
    c = {} unless c.is_a?(Hash)
    {
      "axis"       => (c["axis"] == "horizontal" ? "horizontal" : "vertical"),
      "viewbox"    => c["viewbox"].to_s.presence || "0 0 200 200",
      "defs"       => SvgSanitizer.clean(c["defs"].to_s),
      "fill_clip"  => SvgSanitizer.clean(c["fill_clip"].to_s),
      "fill_color" => c["fill_color"].to_s,
      "back"       => SvgSanitizer.clean(c["back"].to_s),
      "front"      => SvgSanitizer.clean(c["front"].to_s),
      "thumb"      => SvgSanitizer.clean(c["thumb"].to_s)
    }
  end

  def normalize_reaction(r)
    r = {} unless r.is_a?(Hash)
    mode = r["mode"].to_s == "fill" ? "fill" : "states"
    base = { "mode" => mode, "viewbox" => r["viewbox"].to_s.presence || "0 0 200 200", "defs" => SvgSanitizer.clean(r["defs"].to_s) }
    if mode == "fill"
      base.merge("clip" => SvgSanitizer.clean(r["clip"].to_s), "back" => SvgSanitizer.clean(r["back"].to_s),
                 "front" => SvgSanitizer.clean(r["front"].to_s), "liquid_color" => r["liquid_color"].to_s)
    else
      base.merge("states" => Array(r["states"]).first(5).map { |s| { "label" => s["label"].to_s, "svg" => SvgSanitizer.clean(s["svg"].to_s) } })
    end
  end

  def tool_use?(block)
    type = block.respond_to?(:type) ? block.type : block[:type] || block["type"]
    type.to_s == "tool_use"
  end

  def input_of(block)
    raw = block.respond_to?(:input) ? block.input : (block[:input] || block["input"])
    raw.respond_to?(:to_h) ? raw.to_h : raw
  end

  def deep_stringify(obj)
    case obj
    when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
    when Array then obj.map { |v| deep_stringify(v) }
    else obj
    end
  end
end
