require "test_helper"

# RichTextSanitizer is the gate between contenteditable innerHTML and the
# cards JSON, and the equivalence guard is what keeps the html layer from ever
# disagreeing with the canonical plain text.
class RichTextSanitizerTest < ActiveSupport::TestCase
  test "formatting tags and allowlisted span classes survive" do
    out = RichTextSanitizer.clean(%(Hello <b>bold</b> <span class="font-anton size-l">big</span>))

    assert_includes out, "<b>bold</b>"
    assert_includes out, %(<span class="font-anton size-l">big</span>)
  end

  test "scripts, handlers, styles and unknown classes are stripped or unwrapped" do
    out = RichTextSanitizer.clean(
      %(<script>alert(1)</script><a href="https://evil.example">link</a> ) +
      %(<span style="color:red" onclick="x()" class="font-anton hax">styled</span><div>block</div>)
    )

    refute_match(/script|onclick|style=|href|evil/, out)
    refute_includes out, "<a"
    refute_includes out, "<div"
    assert_includes out, "link", "unwrapping keeps the text"
    assert_includes out, "block"
    assert_includes out, %(<span class="font-anton">styled</span>), "the known token survives, the junk one goes"
  end

  test "a span left with no accepted classes loses the attribute entirely" do
    out = RichTextSanitizer.clean(%(<span class="totally-fake">x</span>))
    assert_equal "<span>x</span>", out
  end

  test "clean_equivalent enforces the plain-text contract" do
    assert_equal "<b>Hello</b>", RichTextSanitizer.clean_equivalent("<b>Hello</b>", "Hello")
    assert_nil RichTextSanitizer.clean_equivalent("<b>Goodbye</b>", "Hello"),
               "a diverged html layer must never persist"
    assert_nil RichTextSanitizer.clean_equivalent("<b>Hello</b>", ""),
               "no plain twin, no html layer"
    assert_nil RichTextSanitizer.clean_equivalent("", "Hello")
    # Whitespace differences are tolerated — contenteditable is messy.
    assert RichTextSanitizer.clean_equivalent("<b>Hello </b> world", "Hello world")
  end

  test "clean_equivalent rejects grossly oversized markup" do
    bloated = ("<b></b>" * 400) + "<b>Hi</b>"
    assert_nil RichTextSanitizer.clean_equivalent(bloated, "Hi")
  end

  test "the class allowlists match the CSS and the JS mirror" do
    css = File.read(Rails.root.join("app/assets/tailwind/application.css"))
    RichTextSanitizer::ALLOWED_CLASSES.each do |cls|
      assert_includes css, ".#{cls} ", "#{cls} is accepted by the sanitiser but styled nowhere"
    end

    js = File.read(Rails.root.join("app/javascript/lib/rich_text.js"))
    js_fonts = js[/export const FONT_CLASSES = \[(.*?)\]/m, 1].scan(/"([^"]+)"/).flatten
    js_sizes = js[/export const SIZE_CLASSES = \[(.*?)\]/m, 1].scan(/"([^"]+)"/).flatten
    assert_equal RichTextSanitizer::FONT_CLASSES, js_fonts
    assert_equal RichTextSanitizer::SIZE_CLASSES, js_sizes
  end

  test "every @font-face src file actually exists" do
    css = File.read(Rails.root.join("app/assets/tailwind/application.css"))
    css.scan(%r{url\("/fonts/([^"]+)"\)}).flatten.uniq.each do |file|
      assert File.exist?(Rails.root.join("public/fonts", file)),
             "@font-face references /fonts/#{file} but the file isn't shipped"
    end
  end
end
