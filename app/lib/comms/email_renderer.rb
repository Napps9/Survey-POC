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

    def render_row(block, settings)
      v_pad = block["type"] == "spacer" ? 0 : 12
      %(<tr><td style="padding:#{v_pad}px 24px;">#{render_block(block, settings)}</td></tr>)
    end

    def render_block(block, s)
      case block["type"]
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

    # A heading/text block's body: the sanitized rich twin with class tokens
    # resolved to inline styles when it survives the gate, else the escaped
    # plain text. Re-sanitising at render is defence in depth, same as
    # rich_card_text.
    def rich_or_plain(block, base_px, link_color)
      html = block["text_html"]
      if html.present?
        cleaned = RichTextSanitizer.clean_equivalent(
          html, block["text"], tags: RichTextSanitizer::EMAIL_ALLOWED_TAGS
        )
        return inline_styles(cleaned, base_px, link_color) if cleaned
      end
      multiline(block["text"])
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
