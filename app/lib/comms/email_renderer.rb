# Turns a Comms::EmailDocument into the two payloads a send needs: a
# table-based HTML body that survives Gmail / Outlook / Apple Mail, and a
# plain-text fallback. A port of Temple's src/lib/email/render.ts (minus its
# editable-canvas branch — the builder here edits real DOM, not the compiled
# artifact), extended for the rich-text twin: sanitized `text_html` is
# compiled with class tokens resolved to literal inline styles, because email
# clients understand neither our stylesheet nor CSS custom properties.
#
# The compiled HTML carries a literal {{unsubscribe_url}} token in the
# footer. The delivery worker swaps that per recipient (and wraps links +
# injects the open pixel); the in-app preview passes "#" so the token never
# shows to the author.
module Comms
  module EmailRenderer
    module_function

    UNSUBSCRIBE_PLACEHOLDER = "{{unsubscribe_url}}".freeze
    SAFE_HREF = /\A(https?:|mailto:)/i

    HEADING_SIZES = { 1 => 28, 2 => 22, 3 => 18 }.freeze
    TEXT_SIZE = 16

    # The em-relative size tokens are resolved against the containing
    # block's base size at compile time — email has no inheritance context
    # to lean on (application.css:2064's reasoning, inverted).
    SIZE_FACTORS = { "size-s" => 0.85, "size-l" => 1.25, "size-xl" => 1.5 }.freeze

    def render_html(doc, preheader: nil, unsubscribe_url: nil,
                    footer_business: "Playverto", footer_address: ENV["COMMS_POSTAL_ADDRESS"])
      s = doc["settings"]
      rows = Array(doc["blocks"]).map { |b| render_row(b, s) }.join
      footer = render_footer(unsubscribe_url, footer_business, footer_address)
      pre =
        if preheader.present?
          %(<span style="display:none!important;visibility:hidden;opacity:0;color:transparent;) +
            %(height:0;width:0;overflow:hidden;mso-hide:all;">#{h(preheader)}</span>)
        else
          ""
        end
      %(<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">) +
        %(<meta name="viewport" content="width=device-width,initial-scale=1">) +
        %(<meta name="x-apple-disable-message-reformatting"></head>) +
        %(<body style="margin:0;padding:0;background-color:#{s["backgroundColor"]};font-family:#{s["fontFamily"]};">) +
        pre +
        %(<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="background-color:#{s["backgroundColor"]};">) +
        %(<tr><td align="center" style="padding:24px 12px;">) +
        %(<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="#{s["contentWidth"]}" ) +
        %(style="width:100%;max-width:#{s["contentWidth"]}px;background-color:#{s["contentBackgroundColor"]};border-radius:12px;overflow:hidden;">) +
        rows + footer +
        %(</table></td></tr></table></body></html>)
    end

    # Plain-text alternative, same order, so a text-only client reads the
    # campaign coherently.
    def render_text(doc, unsubscribe_url: nil,
                    footer_business: "Playverto", footer_address: ENV["COMMS_POSTAL_ADDRESS"])
      parts = []
      Array(doc["blocks"]).each do |b|
        case b["type"]
        when "heading", "text"
          parts << b["text"].strip if b["text"].to_s.strip.present?
        when "masthead"
          line = [ b["text"].to_s.strip.presence || b["alt"].to_s.strip, b["eyebrow"].to_s.strip ]
          parts << line.reject(&:blank?).join(" — ") if line.any?(&:present?)
        when "feature"
          item = []
          item << b["eyebrow"].to_s.strip.upcase if b["eyebrow"].to_s.strip.present?
          item << b["text"].to_s.strip if b["text"].to_s.strip.present?
          item << b["body"].to_s.strip if b["body"].to_s.strip.present?
          href = safe_href(b["href"])
          item << "#{b["linkLabel"].to_s.strip.presence || "Read more"}: #{href}" if href.present?
          parts << item.join("\n") if item.any?
        when "callout"
          item = []
          item << "#{b["eyebrow"].to_s.strip.upcase}:" if b["eyebrow"].to_s.strip.present?
          item << b["text"].to_s.strip if b["text"].to_s.strip.present?
          parts << item.join("\n") if item.any?
        when "button"
          href = safe_href(b["href"])
          parts << (href.present? ? "#{b["text"]}: #{href}" : b["text"])
        when "image"
          parts << "[#{b["alt"].strip}]" if b["alt"].to_s.strip.present?
        when "divider"
          parts << "-" * 20
        end
      end
      footer = []
      footer << footer_business.strip if footer_business.to_s.strip.present?
      footer << footer_address.strip if footer_address.to_s.strip.present?
      footer << "Unsubscribe: #{unsubscribe_url || UNSUBSCRIBE_PLACEHOLDER}"
      parts << "-" * 20
      parts << footer.join("\n")
      parts.join("\n\n")
    end

    def h(input)
      input.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
           .gsub('"', "&quot;").gsub("'", "&#39;")
    end

    def multiline(input)
      h(input).gsub(/\r?\n/, "<br>")
    end

    # Only http(s) and mailto ride into an inbox; a stray "javascript:"
    # doesn't.
    def safe_href(href)
      trimmed = href.to_s.strip
      trimmed.match?(SAFE_HREF) ? trimmed : ""
    end

    # The masthead is a full-bleed band: it owns its own padding so its
    # background reaches the edges of the content table.
    FULL_BLEED = %w[masthead].freeze

    def render_row(block, settings)
      return %(<tr><td style="padding:0;">#{render_block(block, settings)}</td></tr>) if
        FULL_BLEED.include?(block["type"])

      v_pad = block["type"] == "spacer" ? 0 : 12
      %(<tr><td style="padding:#{v_pad}px 24px;">#{render_block(block, settings)}</td></tr>)
    end

    def render_block(block, s)
      case block["type"]
      when "masthead"
        render_masthead(block)
      when "feature"
        render_feature(block, s)
      when "callout"
        render_callout(block, s)
      when "heading"
        size = HEADING_SIZES.fetch(block["level"], 22)
        body = rich_or_plain(block, size, s["linkColor"])
        %(<h#{block["level"]} style="margin:0;font-weight:#{s["headingWeight"]};font-size:#{size}px;) +
          %(line-height:1.3;color:#{block["color"]};text-align:#{block["align"]};) +
          %(text-transform:#{s["headingTransform"]};letter-spacing:#{s["headingLetterSpacing"]}px;">) +
          %(#{body}</h#{block["level"]}>)
      when "text"
        body = rich_or_plain(block, TEXT_SIZE, s["linkColor"])
        %(<div style="margin:0;font-size:#{TEXT_SIZE}px;line-height:1.6;color:#{block["color"]};) +
          %(text-align:#{block["align"]};">#{body}</div>)
      when "button"
        href = safe_href(block["href"]).presence || "#"
        # Bulletproof button: an outer table for the background + radius the
        # clients respect, an inner padded <a> for the click target.
        %(<table role="presentation" border="0" cellpadding="0" cellspacing="0" align="#{block["align"]}">) +
          %(<tr><td style="background-color:#{block["backgroundColor"]};border-radius:#{block["radius"]}px;">) +
          %(<a href="#{h(href)}" target="_blank" style="display:inline-block;padding:12px 24px;) +
          %(font-size:16px;font-weight:600;color:#{block["textColor"]};text-decoration:none;) +
          %(border-radius:#{block["radius"]}px;">#{h(block["text"])}</a></td></tr></table>)
      when "image"
        return "" if block["src"].blank?

        img = %(<img src="#{h(block["src"])}" alt="#{h(block["alt"])}" ) +
              %(style="display:inline-block;width:#{block["widthPct"]}%;max-width:100%;height:auto;) +
              %(border:0;outline:none;text-decoration:none;" />)
        href = safe_href(block["href"])
        inner = href.present? ? %(<a href="#{h(href)}" target="_blank">#{img}</a>) : img
        %(<div style="text-align:#{block["align"]};">#{inner}</div>)
      when "divider"
        %(<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%"><tr>) +
          %(<td style="border-top:1px solid #{block["color"]};font-size:0;line-height:0;">&nbsp;</td></tr></table>)
      when "spacer"
        %(<div style="height:#{block["height"]}px;line-height:#{block["height"]}px;font-size:0;">&nbsp;</div>)
      else
        ""
      end
    end

    # The branded band across the top. A logo when one is set (email clients
    # don't render SVG, so this must be a raster src), otherwise the wordmark
    # as live text — a masthead that silently disappears when an image is
    # blocked is worse than one made of letters.
    def render_masthead(b)
      logo =
        if b["src"].present?
          # Most clients block images by default, so the alt text is the
          # masthead a good share of readers actually see: it inherits these
          # type styles and the band's colour rather than rendering as small
          # blue link text.
          %(<img src="#{h(b["src"])}" alt="#{h(b["alt"].presence || b["text"])}" width="180" ) +
            %(style="display:inline-block;width:180px;max-width:60%;height:auto;border:0;) +
            %(outline:none;text-decoration:none;font-size:24px;font-weight:700;) +
            %(letter-spacing:-0.5px;color:#{b["textColor"]};" />)
        else
          %(<span style="font-size:26px;font-weight:700;letter-spacing:-0.5px;) +
            %(color:#{b["textColor"]};">#{h(b["text"])}</span>)
        end
      href = safe_href(b["href"])
      if href.present?
        logo = %(<a href="#{h(href)}" target="_blank" ) +
               %(style="text-decoration:none;color:#{b["textColor"]};">#{logo}</a>)
      end

      eyebrow =
        if b["eyebrow"].to_s.strip.present?
          %(<div style="margin-top:10px;font-size:12px;line-height:1.5;letter-spacing:0.14em;) +
            %(text-transform:uppercase;color:#{b["textColor"]};opacity:0.75;">#{h(b["eyebrow"])}</div>)
        else
          ""
        end

      %(<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" ) +
        %(style="background-color:#{b["backgroundColor"]};"><tr>) +
        %(<td align="#{b["align"]}" style="padding:28px 24px;text-align:#{b["align"]};">) +
        %(#{logo}#{eyebrow}</td></tr></table>)
    end

    # One piece of news as a card: an accent bar down the left (a border, not
    # an image — it survives image blocking), an eyebrow, a title, prose and
    # an optional link.
    def render_feature(b, s)
      parts = []
      if b["eyebrow"].to_s.strip.present?
        parts << %(<div style="font-size:11px;font-weight:700;letter-spacing:0.14em;) +
                  %(text-transform:uppercase;color:#{b["accentColor"]};margin:0 0 6px;">) +
                  %(#{h(b["eyebrow"])}</div>)
      end
      if b["text"].to_s.strip.present?
        parts << %(<div style="font-size:18px;font-weight:700;line-height:1.35;) +
                  %(color:#{b["textColor"]};margin:0;">#{multiline(b["text"])}</div>)
      end
      if b["body"].to_s.strip.present?
        body = rich_or_plain_field(b, "body", TEXT_SIZE, s["linkColor"])
        parts << %(<div style="font-size:15px;line-height:1.6;color:#{b["textColor"]};) +
                  %(margin:8px 0 0;opacity:0.9;">#{body}</div>)
      end
      href = safe_href(b["href"])
      if href.present?
        label = b["linkLabel"].to_s.strip.presence || "Read more"
        parts << %(<div style="margin:12px 0 0;"><a href="#{h(href)}" target="_blank" ) +
                  %(style="font-size:14px;font-weight:600;color:#{b["accentColor"]};) +
                  %(text-decoration:none;">#{h(label)} &rarr;</a></div>)
      end

      %(<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" ) +
        %(style="background-color:#{b["backgroundColor"]};border-left:4px solid #{b["accentColor"]};) +
        %(border-radius:6px;"><tr><td style="padding:16px 18px;">#{parts.join}</td></tr></table>)
    end

    # A tinted panel for something that should sit outside the flow.
    def render_callout(b, s)
      label =
        if b["eyebrow"].to_s.strip.present?
          %(<div style="font-size:11px;font-weight:700;letter-spacing:0.14em;) +
            %(text-transform:uppercase;color:#{b["accentColor"]};margin:0 0 8px;">) +
            %(#{h(b["eyebrow"])}</div>)
        else
          ""
        end
      body = rich_or_plain_field(b, "text", TEXT_SIZE, s["linkColor"])

      %(<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" ) +
        %(style="background-color:#{b["backgroundColor"]};border-radius:8px;">) +
        %(<tr><td style="padding:18px 20px;">#{label}) +
        %(<div style="font-size:#{TEXT_SIZE}px;line-height:1.6;color:#{b["textColor"]};">) +
        %(#{body}</div></td></tr></table>)
    end

    # A heading/text block's body: the sanitized rich twin with class tokens
    # resolved to inline styles when it survives the gate, else the escaped
    # plain text. Re-sanitising at render is defence in depth, same as
    # rich_card_text.
    def rich_or_plain(block, base_px, link_color)
      rich_or_plain_field(block, "text", base_px, link_color)
    end

    # The same rule for any prose field that carries a twin (feature bodies
    # and callouts keep theirs under a different key).
    def rich_or_plain_field(block, field, base_px, link_color)
      html = block["#{field}_html"]
      if html.present?
        cleaned = RichTextSanitizer.clean_equivalent(
          html, block[field], tags: RichTextSanitizer::EMAIL_ALLOWED_TAGS
        )
        return inline_styles(cleaned, base_px, link_color) if cleaned
      end
      multiline(block[field])
    end

    # Rewrites the sanitizer's class tokens into literal inline styles: font
    # tokens via the same per-token CSS stacks the Verto editor stores
    # (Survey::BRAND_FONTS), size tokens against this block's base px.
    # Nested size spans intentionally resolve against the block base, not
    # each other — the toolbar builds flat spans.
    def inline_styles(fragment_html, base_px, link_color)
      doc = Nokogiri::HTML5.fragment(fragment_html)
      doc.css("span[class]").each do |span|
        styles = []
        span["class"].to_s.split(/\s+/).each do |token|
          if (font = Survey::BRAND_FONTS[token])
            styles << "font-family:#{font[:stack]}"
          elsif (factor = SIZE_FACTORS[token])
            styles << "font-size:#{(base_px * factor).round}px"
          end
        end
        span.remove_attribute("class")
        span["style"] = styles.join(";") if styles.any?
      end
      doc.css("a").each do |a|
        a["style"] = "color:#{link_color};text-decoration:underline;"
        a["target"] = "_blank"
      end
      doc.to_html
    end

    def render_footer(unsubscribe_url, business, address)
      unsub = unsubscribe_url || UNSUBSCRIBE_PLACEHOLDER
      lines = []
      lines << h(business.strip) if business.to_s.strip.present?
      lines << multiline(address.strip) if address.to_s.strip.present?
      lines << (%(You're receiving this from #{h(business.to_s.strip.presence || "Playverto")}. ) +
                %(<a href="#{h(unsub)}" target="_blank" style="color:#94A3B8;text-decoration:underline;">Unsubscribe</a>.))
      %(<tr><td style="padding:24px;border-top:1px solid #E2E8F0;">) +
        %(<div style="margin:0;font-size:12px;line-height:1.6;color:#94A3B8;text-align:center;">) +
        %(#{lines.join("<br>")}</div></td></tr>)
    end
  end
end
