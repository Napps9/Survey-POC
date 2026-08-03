require "nokogiri"

# Sanitises the rich-text layer of card content (`text_html`,
# `description_html`, `options_html[]`, per-page `html`) down to a hard
# allowlist: a handful of formatting tags, and `class` on <span> restricted to
# the font/size tokens defined once in application.css. No style attributes,
# ever — a font is a class token or it doesn't exist.
#
# Plain text stays the canonical layer (grading, aggregation, exports, AI,
# i18n all key off it); HTML is presentation only. Survey.sanitize_cards_images!
# enforces that with an equivalence guard: an html value whose visible text
# has drifted from its plain twin is dropped, so the two can never disagree.
#
# Mirrored client-side by lib/rich_text.js (allowlists only — the browser
# builds markup, this class is the authority).
module RichTextSanitizer
  module_function

  ALLOWED_TAGS = %w[b strong i em u span br].freeze

  # Unwrapping keeps children — right for a <div> of text, wrong for elements
  # whose content was never visible text. These go entirely.
  DROP_WITH_CONTENT = %w[script style noscript template iframe object svg textarea select].freeze

  FONT_CLASSES = %w[font-anton font-spectral font-lora font-poppins font-caveat font-alata font-abeezee].freeze
  SIZE_CLASSES = %w[size-s size-l size-xl].freeze
  ALLOWED_CLASSES = (FONT_CLASSES + SIZE_CLASSES).freeze

  # Generous multiple of the plain text: markup wraps text, it doesn't dwarf
  # it. Anything bigger is either an attack or a bug, and either way the plain
  # layer still renders.
  LENGTH_FACTOR = 4
  MIN_BUDGET    = 400

  # Returns the cleaned fragment as a String ("" for blank input). Disallowed
  # elements are unwrapped (their text survives); disallowed attributes and
  # class tokens are dropped.
  def clean(fragment)
    str = fragment.to_s
    return "" if str.strip.empty?

    doc = Nokogiri::HTML5.fragment(str)
    doc.children.each { |node| scrub(node) }
    doc.to_html
  rescue => e
    Rails.logger.warn("[RichTextSanitizer] dropped fragment: #{e.class}: #{e.message}") if defined?(Rails)
    ""
  end

  # The visible text of a fragment — what the equivalence guard compares
  # against the plain field (whitespace-normalised on both sides).
  def plain(fragment)
    Nokogiri::HTML5.fragment(fragment.to_s).text
  rescue StandardError
    ""
  end

  def normalized_plain(value)
    value.to_s.gsub(/\s+/, " ").strip
  end

  # nil unless `html` survives sanitising AND still reads as `plain_text`.
  # This is the single gate every *_html key passes on its way into the cards
  # JSON — a diverged, oversized or empty html layer stores nothing.
  def clean_equivalent(html, plain_text)
    return nil if html.blank? || plain_text.to_s.strip.empty?
    return nil if html.to_s.length > [ plain_text.to_s.length * LENGTH_FACTOR, MIN_BUDGET ].max

    cleaned = clean(html)
    return nil if cleaned.blank?
    return nil unless normalized_plain(plain(cleaned)) == normalized_plain(plain_text)

    cleaned
  end

  def scrub(node)
    if node.element?
      name = node.name.downcase
      if DROP_WITH_CONTENT.include?(name)
        node.remove
        return
      end
      unless ALLOWED_TAGS.include?(name)
        # Unwrap: keep the text/children, lose the element.
        node.children.each { |child| scrub(child) }
        node.replace(Nokogiri::XML::NodeSet.new(node.document, node.children))
        return
      end
      node.attribute_nodes.each do |attr|
        if node.name.downcase == "span" && attr.name.downcase == "class"
          kept = attr.value.split(/\s+/).select { |token| ALLOWED_CLASSES.include?(token) }
          kept.any? ? attr.value = kept.join(" ") : attr.unlink
        else
          attr.unlink
        end
      end
      node.children.each { |child| scrub(child) }
    elsif node.text?
      # keep
    else
      node.remove
    end
  end
end
