require "anthropic"

# Generates the themed reactive visual for an NPS card: the asset that doubles
# as the slider on the right of the card. Kept as its OWN Claude call (not part
# of emit_survey) so the SVGs don't blow the survey-generation token budget.
#
# Output is normalised + sanitized into the shape NpsHelper#nps_visual_spec
# expects. Two modes:
#   "fill"   — a vessel (clip/back/front + liquid_color) whose liquid rises
#   "states" — up to 5 cross-faded SVG expressions
class NpsVisualGenerator
  MODEL      = "claude-sonnet-4-6"
  MAX_TOKENS = 6000

  TOOL = {
    name: "emit_nps_visual",
    description: "Emit a themed, reactive SVG asset that doubles as the NPS slider control.",
    input_schema: {
      type: "object",
      properties: {
        subject: { type: "string", description: "Short metaphor name, e.g. 'thermometer', 'coffee cup', 'plant', 'battery'." },
        mode:    { type: "string", enum: %w[fill states],
                   description: "fill = a container whose liquid rises with the rating (preferred for vessels/gauges). states = 5 cross-faded expressions (for faces/characters)." },
        viewbox: { type: "string", description: "Square SVG viewBox, e.g. '0 0 200 200'." },
        defs:    { type: "string", description: "Optional inner <defs> content (gradients). No clipPath needed for the liquid." },
        liquid_color: { type: "string", description: "fill mode: liquid colour. Prefer 'hsl(var(--nps-hue,140) 80% 50%)' to tween red→green, or a fixed on-theme colour." },
        clip:    { type: "string", description: "fill mode: the vessel INTERIOR shape(s) the liquid fills (e.g. <rect/> + <circle/>, or a <path/>)." },
        back:    { type: "string", description: "fill mode: SVG drawn BEHIND the liquid (optional)." },
        front:   { type: "string", description: "fill mode: vessel outline + details drawn ON TOP (use fill=\"none\" for outlines)." },
        states:  { type: "array", minItems: 3, maxItems: 5,
                   description: "states mode: ordered low→high (5 preferred). Each svg is a layered <g> body.",
                   items: { type: "object",
                            properties: { label: { type: "string" }, svg: { type: "string" } },
                            required: %w[svg] } }
      },
      required: %w[subject mode viewbox]
    }
  }.freeze

  SYSTEM = <<~PROMPT.freeze
    You design ONE small, iconic SVG asset that doubles as the answer control for
    a Verto "NPS / reactive scale" question. The respondent drags the asset and it
    reacts live. Make it fit the survey's THEME, AUDIENCE and TONE.

    Choose ONE mode:
    • "fill" (preferred for vessels/gauges): a container whose liquid rises as the
      rating increases. Supply:
        - clip:  the vessel INTERIOR shape (liquid is clipped to this).
        - back:  anything drawn behind the liquid (optional).
        - front: the vessel outline + details drawn on top, so the liquid shows
                 through (draw outlines with fill="none").
        - liquid_color: prefer "hsl(var(--nps-hue,140) 80% 50%)" so the colour
          tweens red→green with sentiment; or a fixed on-theme colour.
      The app adds and scales the liquid itself from your clip — you only supply
      clip/back/front/liquid_color. Ideas: thermometer, coffee cup, water glass,
      battery, fuel gauge, beaker, watering can, rocket fuel.
    • "states" (for faces/characters): supply 5 ordered SVG <g> bodies (low→high)
      that the app cross-fades. Use fill="hsl(var(--nps-hue,60) 82% 58%)" for mood
      colour so it tweens.

    Rules:
    - Square viewBox, default "0 0 200 200". Simple, iconic, centred; each SVG
      piece under ~1.5KB.
    - You MAY use brand colours via var(--brand-primary), var(--brand-cta),
      var(--brand-text), and hsl(var(--nps-hue) ...) for sentiment.
    - Use ONLY these tags: g, path, circle, ellipse, rect, line, polyline,
      polygon, defs, linearGradient, radialGradient, stop, clipPath, use, title.
      Use ONLY presentation attributes (fill, stroke, d, transform, …).
    - NO <script>, <foreignObject>, <image>, <style>, event handlers (on*),
      external URLs, or href to anything but a local "#id".
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

      Design the reactive asset for THIS question. Pick the mode and metaphor that
      best fit the theme, audience and tone. Output via the emit_nps_visual tool.
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

  # Sanitize + shape the raw tool input into a stored nps_visual spec. Public so
  # it can be unit-tested without an API call.
  def normalize(input)
    mode = input["mode"].to_s == "states" ? "states" : "fill"
    base = {
      "subject" => input["subject"].to_s,
      "mode"    => mode,
      "viewbox" => input["viewbox"].to_s.presence || "0 0 200 200",
      "defs"    => SvgSanitizer.clean(input["defs"].to_s)
    }

    if mode == "fill"
      base.merge(
        "liquid_color" => input["liquid_color"].to_s,
        "clip"         => SvgSanitizer.clean(input["clip"].to_s),
        "back"         => SvgSanitizer.clean(input["back"].to_s),
        "front"        => SvgSanitizer.clean(input["front"].to_s)
      )
    else
      base.merge(
        "states" => Array(input["states"]).first(5).map do |s|
          { "label" => s["label"].to_s, "svg" => SvgSanitizer.clean(s["svg"].to_s) }
        end
      )
    end
  end

  private

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
