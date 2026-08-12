# Per-recipient personalization of the frozen artifact, in Temple's order:
# (1) the unsubscribe URL first — by construction it can never be
# click-wrapped, (2) link tokens → per-recipient redirect URLs, (3) the open
# pixel before </body> (appended when there is no body tag). Text part gets
# the unsubscribe swap only. Personalizing twice is a no-op: every
# placeholder is consumed by the first pass.
module Comms
  module Personalizer
    module_function

    LINK_TOKEN = /\{\{link:(\d+)\}\}/

    def html(compiled_html, unsubscribe_url:, links: {}, pixel_url: nil)
      out = compiled_html.gsub(EmailRenderer::UNSUBSCRIBE_PLACEHOLDER, unsubscribe_url)
      out = out.gsub(LINK_TOKEN) { links.fetch(Regexp.last_match(1).to_i, "#") }
      return out unless pixel_url

      pixel = %(<img src="#{pixel_url}" width="1" height="1" alt="" style="display:none;border:0;" />)
      out.include?("</body>") ? out.sub("</body>", "#{pixel}</body>") : out + pixel
    end

    def text(compiled_text, unsubscribe_url:)
      compiled_text.gsub(EmailRenderer::UNSUBSCRIBE_PLACEHOLDER, unsubscribe_url)
    end
  end
end
