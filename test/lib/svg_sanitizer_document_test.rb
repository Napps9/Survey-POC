require "test_helper"

# clean_document is the gate every stored SVG (org logos, brand-library
# assets) passes through before being served INLINE as image/svg+xml — see
# config/initializers/active_storage.rb. What these pin: scripts and event
# handlers can never survive, and a legitimate tool-exported logo (text,
# tspan, style attributes, missing xmlns) comes out both safe and renderable.
class SvgSanitizerDocumentTest < ActiveSupport::TestCase
  # Shaped like a real design-tool export: XML prolog, comment, <style> block,
  # text with per-element styling — not a hand-minimal fixture.
  REALISTIC_LOGO = <<~SVG.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Exported from a design tool -->
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 60" width="200" height="60">
      <style>.wordmark { fill: #01EACB; }</style>
      <defs>
        <linearGradient id="g" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stop-color="#01EACB"/>
          <stop offset="1" stop-color="#1C2034"/>
        </linearGradient>
      </defs>
      <rect x="0" y="0" width="60" height="60" rx="12" fill="url(#g)"/>
      <text x="70" y="38" font-family="Arial" font-size="24" style="fill:#01EACB;letter-spacing:0.05em">
        Acme<tspan dx="4" font-weight="700">Co</tspan>
      </text>
    </svg>
  SVG

  test "a realistic exported logo keeps its shapes, text and styling" do
    out = SvgSanitizer.clean_document(REALISTIC_LOGO)

    assert out.present?
    assert_includes out, %(xmlns="http://www.w3.org/2000/svg"), "must stay renderable in <img>"
    assert_includes out, "<rect"
    assert_includes out, "linearGradient"
    assert_includes out, "viewBox=", "camelCase attributes must survive XML round-trip"
    assert_includes out, "Acme"
    assert_includes out, "<tspan"
    assert_includes out, "font-weight"
    assert_includes out, "letter-spacing:0.05em", "safe style values must survive"
    refute_includes out, "<style", "CSS blocks are dropped (elements only, not the style attribute)"
    refute_includes out, "<!--"
  end

  test "scripts, event handlers and hostile styles never survive" do
    out = SvgSanitizer.clean_document(<<~SVG)
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
        <script>alert(1)</script>
        <circle cx="5" cy="5" r="4" onclick="alert(2)" style="fill:url(https://evil.example/x)"/>
        <a href="javascript:alert(3)"><rect width="1" height="1"/></a>
        <foreignObject><body xmlns="http://www.w3.org/1999/xhtml"><img src=x onerror=alert(4)></body></foreignObject>
      </svg>
    SVG

    assert out.present?
    refute_match(/script/i, out)
    refute_match(/onclick|onerror/i, out)
    refute_includes out, "evil.example"
    refute_includes out, "javascript:"
    refute_match(/foreignObject/i, out)
    assert_includes out, "<circle", "the circle itself survives, minus its hostile attributes"
  end

  test "a missing xmlns is added so the file renders in <img>" do
    out = SvgSanitizer.clean_document(%(<svg viewBox="0 0 10 10"><rect width="10" height="10"/></svg>))

    assert_includes out, %(xmlns="http://www.w3.org/2000/svg")
  end

  test "non-SVG and empty input are rejected with nil" do
    assert_nil SvgSanitizer.clean_document("")
    assert_nil SvgSanitizer.clean_document("   ")
    assert_nil SvgSanitizer.clean_document("<html><body>hi</body></html>")
    assert_nil SvgSanitizer.clean_document("plain text")
  end

  test "the fragment API is unchanged by the document additions" do
    # text/tspan and style are DOCUMENT allowances; fragments (rendered
    # html_safe inside our own markup) keep the stricter list.
    out = SvgSanitizer.clean(%(<g><text style="fill:red">hi</text><path d="M0 0h10"/></g>))

    refute_includes out, "<text"
    assert_includes out, "<path"
  end
end
