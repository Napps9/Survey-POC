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

  def scrub(node)
    if node.element?
      unless ALLOWED_TAGS.include?(node.name.downcase)
        node.remove
        return
      end
      node.attribute_nodes.each do |attr|
        attr.unlink unless keep_attr?(attr)
      end
      node.children.each { |child| scrub(child) }
    elsif node.comment? || node.cdata?
      node.remove
    elsif node.text?
      # plain text (inside title/desc) is harmless
    else
      node.remove
    end
  end

  def keep_attr?(attr)
    name = attr.name.to_s.downcase
    return false if name.start_with?("on") # event handlers
    if name == "href" || name.end_with?(":href")
      local_ref?(attr.value)
    elsif ALLOWED_ATTRS.include?(name)
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
