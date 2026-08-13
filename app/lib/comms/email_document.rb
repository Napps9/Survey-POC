# The block document a campaign's design column stores and the builder
# edits: {"version" => 1, "settings" => {...}, "blocks" => [...]}. Six block
# types (heading / text / button / image / divider / spacer), a direct port
# of Temple's src/lib/email/blocks.ts so the two suites stay reasoned-about
# the same way.
#
# `design` is untyped JSON, so everything read from the DB (or posted by the
# editor) passes through `coerce` before the renderer or the builder touches
# it: unknown block types and malformed fields are dropped or clamped, never
# thrown on. `sanitize` is coerce plus the rich-text twin gate — the shape
# every save goes through.
#
# Heading and text blocks may carry a `text_html` twin beside their plain
# `text` (the cards-JSON convention): plain is canonical, HTML is
# presentation, and RichTextSanitizer's email profile is the gate.
module Comms
  module EmailDocument
    module_function

    # masthead / feature / callout are composite blocks: one block that
    # renders a whole designed unit (branded header, accent-bar news card,
    # tinted panel). They exist because building those out of heading + text
    # + divider gives you the words without the design, and an author editing
    # six loose blocks per news item cannot keep a newsletter looking like
    # one thing.
    TYPES = %w[masthead heading text feature callout button image divider spacer].freeze
    ALIGNS = %w[left center right].freeze

    # Prose fields that may carry a sanitized rich-text twin (`<field>_html`),
    # per block type. Short labels (eyebrows, link labels) stay plain.
    RICH_FIELDS = {
      "heading" => %w[text], "text" => %w[text],
      "feature" => %w[body], "callout" => %w[text]
    }.freeze

    # What email clients actually render — web fonts mostly don't load, so
    # the default is the system stack, same as Temple.
    SYSTEM_FONT_STACK =
      "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif".freeze

    def default_settings(brand = nil)
      palette = BrandPalette.resolve(brand || {})
      {
        "backgroundColor"        => "#F1F5F9",
        "contentBackgroundColor" => "#FFFFFF",
        "textColor"              => "#0F172A",
        "linkColor"              => palette["primary"],
        "fontFamily"             => SYSTEM_FONT_STACK,
        "contentWidth"           => 600,
        "headingWeight"          => 700,
        "headingTransform"       => "none",
        "headingLetterSpacing"   => 0,
        "buttonRadius"           => 8
      }
    end

    def create_block(type, brand: nil, id: nil)
      palette = BrandPalette.resolve(brand || {})
      id ||= generate_id
      case type.to_s
      when "masthead"
        { "id" => id, "type" => "masthead", "text" => "Playverto", "eyebrow" => "",
          "src" => "", "alt" => "Playverto", "href" => "",
          "backgroundColor" => BrandPalette::DEFAULT["bg"], "textColor" => "#F7F7F7",
          "align" => "center" }
      when "feature"
        { "id" => id, "type" => "feature", "eyebrow" => "NEW",
          "text" => "What your reader can now do", "body" => "One or two sentences on why it helps.",
          "href" => "", "linkLabel" => "",
          "accentColor" => palette["primary"], "backgroundColor" => "#F8FAFC",
          "textColor" => "#0F172A" }
      when "callout"
        { "id" => id, "type" => "callout", "eyebrow" => "Note",
          "text" => "Something worth pulling out of the flow.",
          "accentColor" => palette["primary"], "backgroundColor" => "#F1F5F9",
          "textColor" => "#0F172A" }
      when "heading"
        { "id" => id, "type" => "heading", "text" => "Your headline", "level" => 2,
          "align" => "left", "color" => "#0F172A" }
      when "text"
        { "id" => id, "type" => "text",
          "text" => "Write something your readers will want to read.",
          "align" => "left", "color" => "#0F172A" }
      when "button"
        { "id" => id, "type" => "button", "text" => "Learn more", "href" => "https://",
          "align" => "left", "backgroundColor" => palette["cta"],
          "textColor" => BrandPalette.contrast_text(palette["cta"]), "radius" => 8 }
      when "image"
        { "id" => id, "type" => "image", "src" => "", "alt" => "", "href" => "",
          "widthPct" => 100, "align" => "center" }
      when "divider"
        { "id" => id, "type" => "divider", "color" => "#E2E8F0" }
      when "spacer"
        { "id" => id, "type" => "spacer", "height" => 24 }
      end
    end

    # A reasonable starting canvas so a new campaign is something to edit
    # rather than a blank page.
    def starter_document(brand: nil, org_name: "Playverto", logo_url: nil)
      blocks = []
      if logo_url.present?
        logo = create_block("image", brand: brand)
        logo.merge!("src" => logo_url, "alt" => org_name, "widthPct" => 35, "align" => "center")
        blocks << logo
      end
      heading = create_block("heading", brand: brand)
      heading.merge!("text" => "Hello from #{org_name}", "align" => "center")
      blocks << heading

      text = create_block("text", brand: brand)
      text.merge!(
        "text" => "Use this space to share news, an offer, or an update. " \
                  "Add blocks from the rail to build out your email.",
        "align" => "center"
      )
      blocks << text

      button = create_block("button", brand: brand)
      button["align"] = "center"
      blocks << button

      { "version" => 1, "settings" => default_settings(brand), "blocks" => blocks }
    end

    def coerce(raw, brand: nil)
      defaults = default_settings(brand)
      raw = {} unless raw.is_a?(Hash)
      s = raw["settings"].is_a?(Hash) ? raw["settings"] : {}
      settings = {
        "backgroundColor"        => str(s["backgroundColor"], defaults["backgroundColor"]),
        "contentBackgroundColor" => str(s["contentBackgroundColor"], defaults["contentBackgroundColor"]),
        "textColor"              => str(s["textColor"], defaults["textColor"]),
        "linkColor"              => str(s["linkColor"], defaults["linkColor"]),
        "fontFamily"             => str(s["fontFamily"], defaults["fontFamily"]),
        "contentWidth"           => num(s["contentWidth"], 600).clamp(320, 800),
        "headingWeight"          => num(s["headingWeight"], defaults["headingWeight"]),
        "headingTransform"       => s["headingTransform"] == "uppercase" ? "uppercase" : "none",
        "headingLetterSpacing"   => num(s["headingLetterSpacing"], 0),
        "buttonRadius"           => num(s["buttonRadius"], defaults["buttonRadius"])
      }
      blocks = Array(raw["blocks"]).filter_map { |b| coerce_block(b) }
      { "version" => 1, "settings" => settings, "blocks" => blocks }
    end

    # coerce + the rich-text twin gate: the shape every save passes through.
    # An html twin that fails the email-profile sanitiser (or has drifted
    # from its plain text) stores nothing — same rule as the cards JSON.
    def sanitize(raw, brand: nil)
      doc = coerce(raw, brand: brand)
      doc["blocks"].each do |b|
        RICH_FIELDS.fetch(b["type"], []).each do |field|
          twin = "#{field}_html"
          next unless b.key?(twin)

          cleaned = RichTextSanitizer.clean_equivalent(
            b[twin], b[field], tags: RichTextSanitizer::EMAIL_ALLOWED_TAGS
          )
          cleaned ? b[twin] = cleaned : b.delete(twin)
        end
      end
      doc
    end

    # Human-readable readiness problems (empty = sendable). Gates Send.
    def warnings(doc)
      out = []
      blocks = Array(doc["blocks"])
      out << "The email has no content blocks yet." if blocks.empty?
      blocks.each do |b|
        out << "An image block has no image set." if b["type"] == "image" && b["src"].blank?
        if b["type"] == "button" && (b["href"].blank? || b["href"] == "https://")
          out << "A button block is missing its link."
        end
      end
      out
    end

    def generate_id
      "b_#{SecureRandom.base58(8)}"
    end

    def coerce_block(raw)
      return nil unless raw.is_a?(Hash)

      id = str(raw["id"], nil) || generate_id
      case raw["type"]
      when "masthead"
        { "id" => id, "type" => "masthead", "text" => str(raw["text"], "Playverto"),
          "eyebrow" => str(raw["eyebrow"], ""), "src" => str(raw["src"], ""),
          "alt" => str(raw["alt"], ""), "href" => str(raw["href"], ""),
          "backgroundColor" => str(raw["backgroundColor"], BrandPalette::DEFAULT["bg"]),
          "textColor" => str(raw["textColor"], "#F7F7F7"),
          "align" => align(raw["align"]) }
      when "feature"
        with_html_twin(raw,
                       "id" => id, "type" => "feature", "eyebrow" => str(raw["eyebrow"], ""),
                       "text" => str(raw["text"], ""), "body" => str(raw["body"], ""),
                       "href" => str(raw["href"], ""), "linkLabel" => str(raw["linkLabel"], ""),
                       "accentColor" => str(raw["accentColor"], BrandPalette::DEFAULT["primary"]),
                       "backgroundColor" => str(raw["backgroundColor"], "#F8FAFC"),
                       "textColor" => str(raw["textColor"], "#0F172A"))
      when "callout"
        with_html_twin(raw,
                       "id" => id, "type" => "callout", "eyebrow" => str(raw["eyebrow"], ""),
                       "text" => str(raw["text"], ""),
                       "accentColor" => str(raw["accentColor"], BrandPalette::DEFAULT["primary"]),
                       "backgroundColor" => str(raw["backgroundColor"], "#F1F5F9"),
                       "textColor" => str(raw["textColor"], "#0F172A"))
      when "heading"
        with_html_twin(raw,
                       "id" => id, "type" => "heading", "text" => str(raw["text"], ""),
                       "level" => [ 1, 2, 3 ].include?(raw["level"]) ? raw["level"] : 2,
                       "align" => align(raw["align"]), "color" => str(raw["color"], "#0F172A"))
      when "text"
        with_html_twin(raw,
                       "id" => id, "type" => "text", "text" => str(raw["text"], ""),
                       "align" => align(raw["align"]), "color" => str(raw["color"], "#0F172A"))
      when "button"
        { "id" => id, "type" => "button", "text" => str(raw["text"], "Button"),
          "href" => str(raw["href"], ""), "align" => align(raw["align"]),
          "backgroundColor" => str(raw["backgroundColor"], BrandPalette::DEFAULT["cta"]),
          "textColor" => str(raw["textColor"], "#FFFFFF"),
          "radius" => num(raw["radius"], 8) }
      when "image"
        { "id" => id, "type" => "image", "src" => str(raw["src"], ""),
          "alt" => str(raw["alt"], ""), "href" => str(raw["href"], ""),
          "widthPct" => num(raw["widthPct"], 100).clamp(10, 100),
          "align" => align(raw["align"]) }
      when "divider"
        { "id" => id, "type" => "divider", "color" => str(raw["color"], "#E2E8F0") }
      when "spacer"
        { "id" => id, "type" => "spacer", "height" => num(raw["height"], 24).clamp(4, 160) }
      end
    end

    def with_html_twin(raw, block)
      RICH_FIELDS.fetch(block["type"], []).each do |field|
        twin = "#{field}_html"
        block[twin] = raw[twin] if raw[twin].is_a?(String)
      end
      block
    end

    def str(value, fallback)
      value.is_a?(String) ? value : fallback
    end

    def num(value, fallback)
      value.is_a?(Numeric) && value.to_f.finite? ? value.round : fallback
    end

    def align(value)
      ALIGNS.include?(value) ? value : "left"
    end
  end
end
