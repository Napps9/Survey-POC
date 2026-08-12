module CommsHelper
  # Canvas (editing) rendering of one email block: visually equivalent to the
  # compiled email, structurally editable. Rich twins render their sanitized
  # class-token HTML (the canvas has the stylesheet, so the rich-text toolbar
  # reflects state); the compiler inlines those tokens at send time.
  def comms_block_body(block, settings, editable: true)
    case block["type"]
    when "heading" then comms_heading_body(block, settings, editable)
    when "text"    then comms_text_body(block, editable)
    when "button"  then comms_button_body(block, editable)
    when "image"   then comms_image_body(block)
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
    %w[align color level href backgroundColor textColor radius src alt widthPct height].each do |field|
      next unless block.key?(field)

      attrs["data-block-#{field.underscore.dasherize}"] = block[field]
    end
    tag.attributes(attrs)
  end

  private

  def comms_rich_body(block)
    cleaned = RichTextSanitizer.clean_equivalent(
      block["text_html"], block["text"], tags: RichTextSanitizer::EMAIL_ALLOWED_TAGS
    )
    return cleaned.html_safe if cleaned

    ERB::Util.html_escape(block["text"].to_s).gsub("\n", "<br>").html_safe
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
