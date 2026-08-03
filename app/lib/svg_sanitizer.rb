require "nokogiri"
require "set"

# Sanitizes untrusted SVG fragments (e.g. Claude-generated NPS visuals) before
# they are rendered with `html_safe`. Allowlist-based: anything not explicitly
# permitted is dropped. Strips <script>/<foreignObject>/<image>/<style>, all
# event handlers, and any href/url() that isn't a local "#id" reference.
#
# Input is a fragment (one or more elements, e.g. "<g>…</g>" or gradient defs).
# It is parsed inside a <svg> wrapper with the HTML5 parser so SVG foreign-
# content rules apply (camelCase attrs like viewBox/gradientUnits are preserved
# and namespaced attrs like xlink:href are handled).
module SvgSanitizer
  module_function

  ALLOWED_TAGS = %w[
    svg g path circle ellipse rect line polyline polygon
    defs lineargradient radialgradient stop clippath mask use symbol
    title desc
  ].to_set.freeze

  # Compared case-insensitively (we never rename, only keep/drop).
  ALLOWED_ATTRS = %w[
    id class transform opacity
    d points pathlength
    cx cy r rx ry x y x1 y1 x2 y2 width height
    fill fill-opacity fill-rule
    stroke stroke-width stroke-linecap stroke-linejoin stroke-dasharray
    stroke-dashoffset stroke-opacity stroke-miterlimit
    offset stop-color stop-opacity
    gradientunits gradienttransform spreadmethod
    viewbox preserveaspectratio
    clip-path clip-rule mask
  ].to_set.freeze

  # Whole uploaded SVG *documents* (brand logos / library assets) additionally
  # need text and per-element styling to survive, or real tool-exported logos
  # come out visually gutted. `style` values still go through safe_value?, so
  # javascript:/expression()/remote url() never survive.
  DOCUMENT_TAGS = (ALLOWED_TAGS + %w[text tspan]).freeze
  DOCUMENT_ATTRS = (ALLOWED_ATTRS + %w[
    style dx dy rotate textlength lengthadjust
    font-family font-size font-weight font-style
    text-anchor dominant-baseline letter-spacing word-spacing text-decoration
  ]).freeze

  def clean(fragment)
    str = fragment.to_s
    return "" if str.strip.empty?

    doc = Nokogiri::HTML5.fragment("<svg>#{str}</svg>")
    svg = doc.at_css("svg")
    return "" unless svg

    svg.children.each { |node| scrub(node) }
    svg.inner_html
  rescue => e
    Rails.logger.warn("[SvgSanitizer] dropped fragment: #{e.class}: #{e.message}") if defined?(Rails)
    ""
  end

  # Sanitizes a complete uploaded SVG file (as opposed to a fragment) so it can
  # be stored and later served inline as image/svg+xml. Parses as XML — that is
  # what an <img src> ultimately requires — with Nokogiri's defaults (no
  # network, no entity expansion). Returns the cleaned document as a string, or
  # nil when the input has no usable <svg> root, so callers can reject the
  # upload outright.
  def clean_document(str)
    s = str.to_s
    return nil if s.strip.empty?

    doc = Nokogiri::XML(s)
    root = doc.root
    return nil unless root && root.name.downcase == "svg"

    scrub(root, tags: DOCUMENT_TAGS, attrs: DOCUMENT_ATTRS)
    return nil unless doc.root

    # An SVG document only renders in <img> with its namespace declared. XML
    # namespace declarations aren't attribute_nodes, so scrub never strips
    # them — but tools occasionally omit xmlns, and we must not.
    root.add_namespace(nil, "http://www.w3.org/2000/svg") if root.namespace.nil?
    if root.to_xml.include?("xlink:") && root.namespace_definitions.none? { |ns| ns.prefix == "xlink" }
      root.add_namespace("xlink", "http://www.w3.org/1999/xlink")
    end
    out = root.to_xml
    out.strip.empty? ? nil : out
  rescue => e
    Rails.logger.warn("[SvgSanitizer] rejected document: #{e.class}: #{e.message}") if defined?(Rails)
    nil
  end

  def scrub(node, tags: ALLOWED_TAGS, attrs: ALLOWED_ATTRS)
    if node.element?
      unless tags.include?(node.name.downcase)
        node.remove
        return
      end
      node.attribute_nodes.each do |attr|
        attr.unlink unless keep_attr?(attr, attrs)
      end
      node.children.each { |child| scrub(child, tags: tags, attrs: attrs) }
    elsif node.comment? || node.cdata?
      node.remove
    elsif node.text?
      # plain text (inside title/desc) is harmless
    else
      node.remove
    end
  end

  def keep_attr?(attr, allowed = ALLOWED_ATTRS)
    name = attr.name.to_s.downcase
    return false if name.start_with?("on") # event handlers
    if name == "href" || name.end_with?(":href")
      local_ref?(attr.value)
    elsif allowed.include?(name)
      safe_value?(attr.value)
    else
      false
    end
  end

  def local_ref?(value)
    value.to_s.strip.start_with?("#")
  end

  # Reject javascript:/expression() and any non-local url(...) reference.
  def safe_value?(value)
    s = value.to_s.downcase
    return false if s.include?("javascript:") || s.include?("expression(")
    if s.include?("url(")
      s.scan(/url\(([^)]*)\)/).all? { |m| m[0].gsub(/['"\s]/, "").start_with?("#") }
    else
      true
    end
  end
end
