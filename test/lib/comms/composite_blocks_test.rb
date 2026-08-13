require "test_helper"

# The composite blocks — masthead, feature, callout — that let a campaign look
# designed rather than typed. Each renders as nested tables with literal inline
# styles (no stylesheet, no custom properties reach an inbox) and degrades to
# something readable when an image is blocked or a field is empty.
class Comms::CompositeBlocksTest < ActiveSupport::TestCase
  def doc(blocks)
    Comms::EmailDocument.coerce({ "blocks" => blocks })
  end

  def render(blocks)
    Comms::EmailRenderer.render_html(doc(blocks), unsubscribe_url: "#")
  end

  # ── coercion ───────────────────────────────────────────────────────────────

  test "the new types survive coercion with their fields" do
    blocks = %w[masthead feature callout].map { |t| Comms::EmailDocument.create_block(t) }
    out = doc(blocks)["blocks"]

    assert_equal %w[masthead feature callout], out.map { |b| b["type"] }
    assert_equal "Playverto", out[0]["text"]
    assert_equal "NEW", out[1]["eyebrow"]
    assert out[1]["accentColor"].present?
    assert out[2]["backgroundColor"].present?
  end

  test "junk fields fall back rather than reaching a style attribute" do
    out = doc([ { "type" => "feature", "eyebrow" => 42, "text" => nil,
                  "accentColor" => { "nope" => true } } ])["blocks"].first

    assert_equal "", out["eyebrow"]
    assert_equal "", out["text"]
    assert_equal BrandPalette::DEFAULT["primary"], out["accentColor"]
  end

  test "a feature body and a callout keep a matching rich twin, and lose a drifted one" do
    kept = doc([ { "type" => "feature", "body" => "Bold word",
                   "body_html" => "<strong>Bold</strong> word" } ])["blocks"].first
    assert_equal "<strong>Bold</strong> word", kept["body_html"]

    sanitized = Comms::EmailDocument.sanitize(
      { "blocks" => [ { "type" => "callout", "text" => "Real text",
                        "text_html" => "<strong>Something else entirely</strong>" } ] }
    )["blocks"].first
    assert_not sanitized.key?("text_html"), "a twin that drifted from its plain text is dropped"
  end

  test "composite blocks never trip the send gate" do
    blocks = %w[masthead feature callout].map { |t| Comms::EmailDocument.create_block(t) }
    assert_equal [], Comms::EmailDocument.warnings(doc(blocks))
  end

  # ── masthead ───────────────────────────────────────────────────────────────

  test "a masthead with a logo renders the image; without one it renders the wordmark" do
    with_logo = render([ { "type" => "masthead", "src" => "https://x.test/logo.png",
                           "alt" => "Playverto", "eyebrow" => "Week of 10 August",
                           "backgroundColor" => "#1C2034", "textColor" => "#F7F7F7" } ])
    assert_includes with_logo, "https://x.test/logo.png"
    assert_includes with_logo, "background-color:#1C2034"
    assert_includes with_logo, "Week of 10 August"

    # Image blocked, or none set: the brand still has to say its own name.
    without = render([ { "type" => "masthead", "text" => "Playverto", "src" => "" } ])
    assert_includes without, "Playverto"
    assert_not_includes without, "<img"
  end

  test "a blocked logo falls back to alt text styled like the wordmark, not blue link text" do
    html = render([ { "type" => "masthead", "src" => "https://x.test/logo.png", "alt" => "",
                      "text" => "Playverto", "href" => "https://x.test",
                      "textColor" => "#F7F7F7" } ])

    # Most inboxes block images by default, so this is what many readers see.
    assert_includes html, %(alt="Playverto"), "alt falls back to the wordmark"
    img = html[/<img[^>]*>/]
    assert_includes img, "color:#F7F7F7"
    assert_includes img, "font-weight:700"
    # The wrapping link must not tint the alt text with the client's link blue.
    assert_includes html, %(style="text-decoration:none;color:#F7F7F7;")
  end

  test "the masthead is full-bleed while ordinary rows keep their gutter" do
    html = render([ { "type" => "masthead", "src" => "" }, { "type" => "text", "text" => "Hi" } ])

    assert_includes html, %(<td style="padding:0;">), "the band reaches the paper's edges"
    assert_includes html, %(<td style="padding:12px 24px;">)
  end

  test "an unsafe masthead link is dropped" do
    html = render([ { "type" => "masthead", "text" => "P", "href" => "javascript:alert(1)" } ])
    assert_not_includes html, "javascript:"
  end

  # ── feature ────────────────────────────────────────────────────────────────

  test "a feature renders eyebrow, title, body and an accent bar" do
    html = render([ { "type" => "feature", "eyebrow" => "New", "text" => "Faster imports",
                      "body" => "They just work.", "accentColor" => "#01EACB" } ])

    assert_includes html, "border-left:4px solid #01EACB"
    assert_includes html, "New"
    assert_includes html, "Faster imports"
    assert_includes html, "They just work."
  end

  test "a feature link renders only when safe, with a default label" do
    linked = render([ { "type" => "feature", "text" => "T", "href" => "https://x.test/a" } ])
    assert_includes linked, "https://x.test/a"
    assert_includes linked, "Read more"

    labelled = render([ { "type" => "feature", "text" => "T", "href" => "https://x.test/a",
                          "linkLabel" => "See it" } ])
    assert_includes labelled, "See it"

    unsafe = render([ { "type" => "feature", "text" => "T", "href" => "javascript:alert(1)" } ])
    assert_not_includes unsafe, "javascript:"
    assert_not_includes unsafe, "Read more"
  end

  test "empty feature fields emit nothing rather than empty elements" do
    html = render([ { "type" => "feature", "text" => "Only a title", "eyebrow" => "", "body" => "" } ])

    assert_includes html, "Only a title"
    assert_not_includes html, "margin:8px 0 0"
  end

  test "author text in a composite block is escaped" do
    html = render([ { "type" => "feature", "eyebrow" => "<script>", "text" => "<b>x</b>",
                      "body" => "a & b" } ])

    assert_not_includes html, "<script>"
    assert_includes html, "&lt;b&gt;x&lt;/b&gt;"
    assert_includes html, "a &amp; b"
  end

  # ── callout ────────────────────────────────────────────────────────────────

  test "a callout renders its label and body on its tint" do
    html = render([ { "type" => "callout", "eyebrow" => "Projects", "text" => "Fill me in",
                      "backgroundColor" => "#F1F5F9", "accentColor" => "#615BF5" } ])

    assert_includes html, "Projects"
    assert_includes html, "Fill me in"
    assert_includes html, "background-color:#F1F5F9"
    assert_includes html, "color:#615BF5"
  end

  test "a rich twin in a callout compiles to inline styles" do
    html = render([ { "type" => "callout", "text" => "Read the docs",
                      "text_html" => %(Read <a href="https://x.test">the docs</a>) } ])

    assert_includes html, %(href="https://x.test")
    assert_includes html, "text-decoration:underline"
    assert_includes html, 'target="_blank"'
  end

  # ── plain text ─────────────────────────────────────────────────────────────

  test "the text alternative speaks every composite block" do
    text = Comms::EmailRenderer.render_text(
      doc([ { "type" => "masthead", "text" => "Playverto", "eyebrow" => "Week of 10 August" },
            { "type" => "feature", "eyebrow" => "New", "text" => "Faster imports",
              "body" => "They just work.", "href" => "https://x.test/a", "linkLabel" => "See it" },
            { "type" => "callout", "eyebrow" => "Projects", "text" => "Fill me in" } ]),
      unsubscribe_url: "https://x.test/u"
    )

    assert_includes text, "Playverto — Week of 10 August"
    assert_includes text, "NEW"
    assert_includes text, "Faster imports"
    assert_includes text, "See it: https://x.test/a"
    assert_includes text, "PROJECTS:"
    assert_includes text, "Fill me in"
  end
end
