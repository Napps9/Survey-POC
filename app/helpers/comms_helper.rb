module CommsHelper
  # Canvas (editing) rendering of one email block: visually equivalent to the
  # compiled email, structurally editable. Rich twins render their sanitized
  # class-token HTML (the canvas has the stylesheet, so the rich-text toolbar
  # reflects state); the compiler inlines those tokens at send time.
  def comms_block_body(block, settings, editable: true)
    case block["type"]
    when "heading"  then comms_heading_body(block, settings, editable)
    when "text"     then comms_text_body(block, editable)
    when "button"   then comms_button_body(block, editable)
    when "image"    then comms_image_body(block)
    when "masthead" then comms_masthead_body(block, editable)
    when "feature"  then comms_feature_body(block, editable)
    when "callout"  then comms_callout_body(block, editable)
    when "divider"
      tag.div(class: "comms-div", style: "border-top:1px solid #{h_color(block["color"])};")
    when "spacer"
      tag.div(class: "comms-spacer", style: "height:#{block["height"].to_i}px;") do
        tag.span("#{block["height"].to_i}px")
      end
    end
  end

  # The serializable state a block wrap carries, as data-block-* attributes —
  # the same convention as the survey editor's data-card-* (the DOM is the
  # document; serialize() reads it back).
  def comms_block_data_attrs(block)
    attrs = { "data-block-id" => block["id"], "data-block-type" => block["type"] }
    %w[align color level href backgroundColor textColor radius src alt widthPct height
       accentColor].each do |field|
      next unless block.key?(field)

      attrs["data-block-#{field.underscore.dasherize}"] = block[field]
    end
    tag.attributes(attrs)
  end

  private

  def comms_rich_body(block)
    comms_rich_body_field(block, "text")
  end

  def comms_rich_body_field(block, field)
    cleaned = RichTextSanitizer.clean_equivalent(
      block["#{field}_html"], block[field], tags: RichTextSanitizer::EMAIL_ALLOWED_TAGS
    )
    return cleaned.html_safe if cleaned

    ERB::Util.html_escape(block[field].to_s).gsub("\n", "<br>").html_safe
  end

  def comms_heading_body(block, settings, editable)
    level = block["level"].to_i.clamp(1, 3)
    size = Comms::EmailRenderer::HEADING_SIZES.fetch(level, 22)
    style = "margin:0;font-weight:#{settings["headingWeight"].to_i};font-size:#{size}px;" \
            "line-height:1.3;color:#{h_color(block["color"])};text-align:#{block["align"]};" \
            "text-transform:#{settings["headingTransform"]};" \
            "letter-spacing:#{settings["headingLetterSpacing"].to_i}px;"
    content_tag("h#{level}", comms_rich_body(block),
                style: style, contenteditable: editable ? "true" : nil,
                "data-rich-text": editable ? "" : nil, "data-block-field": "text")
  end

  def comms_text_body(block, editable)
    style = "margin:0;font-size:16px;line-height:1.6;color:#{h_color(block["color"])};" \
            "text-align:#{block["align"]};"
    tag.div(comms_rich_body(block),
            style: style, contenteditable: editable ? "true" : nil,
            "data-rich-text": editable ? "" : nil, "data-block-field": "text")
  end

  def comms_button_body(block, editable)
    tag.div(style: "text-align:#{block["align"]};") do
      tag.span(block["text"].to_s,
               class: "comms-btn", contenteditable: editable ? "true" : nil,
               "data-block-field": "text",
               style: "background:#{h_color(block["backgroundColor"])};" \
                      "color:#{h_color(block["textColor"])};" \
                      "border-radius:#{block["radius"].to_i}px;")
    end
  end

  # The composite blocks. Each editable text run carries data-block-field so
  # serialize() can read it back by name — the same DOM-is-the-document rule
  # as the single-field blocks, just with more than one field per block.
  # What an empty run says when there's nothing in it yet. Without these an
  # optional field is an unexplained empty box on the canvas.
  COMMS_FIELD_PLACEHOLDERS = {
    "eyebrow" => "Label (optional)", "linkLabel" => "Link text (optional)",
    "text" => "Write something…", "body" => "Add a sentence or two…"
  }.freeze

  def comms_editable_run(block, field, style:, editable:, rich: false, tag_name: :div)
    body = rich ? comms_rich_body_field(block, field) : ERB::Util.html_escape(block[field].to_s)
    content_tag(tag_name, body,
                style: style, contenteditable: editable ? "true" : nil,
                "data-rich-text": (editable && rich) ? "" : nil,
                "data-block-field": field,
                "data-placeholder": editable ? COMMS_FIELD_PLACEHOLDERS[field] : nil)
  end

  def comms_masthead_body(block, editable)
    tag.div(class: "comms-masthead",
            style: "background:#{h_color(block["backgroundColor"])};text-align:#{block["align"]};") do
      logo =
        if block["src"].present?
          image_tag(block["src"], alt: block["alt"].to_s, class: "comms-masthead-logo",
                    data: { action: "click->media-picker#openComms" })
        else
          comms_editable_run(block, "text", editable: editable, tag_name: :span,
                             style: "font-size:26px;font-weight:700;letter-spacing:-0.5px;" \
                                    "color:#{h_color(block["textColor"])};")
        end
      eyebrow = comms_editable_run(
        block, "eyebrow", editable: editable,
        style: "margin-top:10px;font-size:12px;letter-spacing:0.14em;text-transform:uppercase;" \
               "color:#{h_color(block["textColor"])};opacity:0.75;min-height:14px;"
      )
      safe_join([ logo, eyebrow ])
    end
  end

  def comms_feature_body(block, editable)
    tag.div(class: "comms-feature",
            style: "background:#{h_color(block["backgroundColor"])};" \
                   "border-left:4px solid #{h_color(block["accentColor"])};") do
      safe_join([
        comms_editable_run(block, "eyebrow", editable: editable,
                           style: "font-size:11px;font-weight:700;letter-spacing:0.14em;" \
                                  "text-transform:uppercase;color:#{h_color(block["accentColor"])};" \
                                  "margin-bottom:6px;min-height:13px;"),
        comms_editable_run(block, "text", editable: editable,
                           style: "font-size:18px;font-weight:700;line-height:1.35;" \
                                  "color:#{h_color(block["textColor"])};"),
        comms_editable_run(block, "body", editable: editable, rich: true,
                           style: "font-size:15px;line-height:1.6;margin-top:8px;opacity:0.9;" \
                                  "color:#{h_color(block["textColor"])};"),
        comms_editable_run(block, "linkLabel", editable: editable,
                           style: "margin-top:12px;font-size:14px;font-weight:600;" \
                                  "color:#{h_color(block["accentColor"])};min-height:16px;")
      ])
    end
  end

  def comms_callout_body(block, editable)
    tag.div(class: "comms-callout", style: "background:#{h_color(block["backgroundColor"])};") do
      safe_join([
        comms_editable_run(block, "eyebrow", editable: editable,
                           style: "font-size:11px;font-weight:700;letter-spacing:0.14em;" \
                                  "text-transform:uppercase;color:#{h_color(block["accentColor"])};" \
                                  "margin-bottom:8px;min-height:13px;"),
        comms_editable_run(block, "text", editable: editable, rich: true,
                           style: "font-size:16px;line-height:1.6;color:#{h_color(block["textColor"])};")
      ])
    end
  end

  def comms_image_body(block)
    if block["src"].present?
      tag.div(style: "text-align:#{block["align"]};") do
        image_tag(block["src"], alt: block["alt"].to_s, class: "comms-img",
                  style: "width:#{block["widthPct"].to_i}%;",
                  data: { action: "click->media-picker#openComms" })
      end
    else
      tag.button("＋ Add image", type: "button", class: "comms-img-empty",
                 data: { action: "click->media-picker#openComms" })
    end
  end

  # Colors land in inline style attributes; allow only hex/rgb-ish tokens so
  # a stored document can't smuggle style syntax.
  def h_color(value)
    v = value.to_s.strip
    v.match?(/\A#[0-9a-fA-F]{3,8}\z/) ? v : "#0F172A"
  end
end
