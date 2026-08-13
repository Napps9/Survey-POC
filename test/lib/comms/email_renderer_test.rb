require "test_helper"

# Ports the intent of Temple's render.test.ts: the compiled artifact is
# table-based inline-styled HTML whose footer always carries the
# {{unsubscribe_url}} token, with author input escaped and unsafe hrefs
# downgraded — plus the VertoNow extension, rich-text twins compiled to
# literal inline styles.
class Comms::EmailRendererTest < ActiveSupport::TestCase
  def doc(blocks: [], settings: {})
    Comms::EmailDocument.coerce({ "settings" => settings, "blocks" => blocks })
  end

  test "footer always contains the unsubscribe placeholder exactly once" do
    html = Comms::EmailRenderer.render_html(doc)

    assert_equal 1, html.scan("{{unsubscribe_url}}").count
  end

  test "the preview override replaces the placeholder" do
    html = Comms::EmailRenderer.render_html(doc, unsubscribe_url: "#")

    assert_not_includes html, "{{unsubscribe_url}}"
    assert_includes html, %(href="#")
  end

  test "author text is escaped and newlines become br" do
    html = Comms::EmailRenderer.render_html(
      doc(blocks: [ { "type" => "text", "text" => "a <script> &\nb" } ])
    )

    assert_includes html, "a &lt;script&gt; &amp;<br>b"
    assert_not_includes html, "<script>"
  end

  test "javascript: hrefs are downgraded" do
    html = Comms::EmailRenderer.render_html(
      doc(blocks: [ { "type" => "button", "text" => "Go", "href" => "javascript:alert(1)" } ])
    )

    assert_includes html, %(href="#")
    assert_not_includes html, "javascript:"
  end

  test "hidden preheader renders escaped, and only when present" do
    with = Comms::EmailRenderer.render_html(doc, preheader: "See <this>")
    without = Comms::EmailRenderer.render_html(doc)

    assert_includes with, "See &lt;this&gt;"
    assert_includes with, "mso-hide:all"
    assert_not_includes without, "mso-hide:all"
  end

  test "the preheader is padded so body copy can't spill into the inbox snippet" do
    html = Comms::EmailRenderer.render_html(doc(blocks: [ { "type" => "text", "text" => "Body copy" } ]),
                                            preheader: "A short line.")
    hidden = html[/<span style="display:none[^>]*>(.*?)<\/span>/m, 1]

    assert hidden.start_with?("A short line.")
    # Whatever the preheader doesn't fill, a client takes from the top of the
    # body — the padding occupies that space without printing anything.
    assert_operator hidden.scan("&zwnj;").size, :>, 50
    assert_not_includes hidden, "Body copy"
  end

  test "a preheader at full length needs no padding" do
    html = Comms::EmailRenderer.render_html(doc, preheader: "x" * 200)
    hidden = html[/<span style="display:none[^>]*>(.*?)<\/span>/m, 1]

    assert_not_includes hidden, "&zwnj;"
  end

  test "contentWidth threads into the shell table" do
    html = Comms::EmailRenderer.render_html(doc(settings: { "contentWidth" => 480 }))

    assert_includes html, %(width="480")
    assert_includes html, "max-width:480px"
  end

  test "an image without src renders nothing; with src it renders width and link" do
    empty = Comms::EmailRenderer.render_html(doc(blocks: [ { "type" => "image", "src" => "" } ]))
    assert_not_includes empty, "<img"

    html = Comms::EmailRenderer.render_html(
      doc(blocks: [ { "type" => "image", "src" => "https://cdn.example/x.png",
                      "widthPct" => 40, "href" => "https://example.com" } ])
    )
    assert_includes html, "width:40%"
    assert_includes html, %(<a href="https://example.com")
  end

  test "spacer rows carry no padding, other rows carry 12px" do
    html = Comms::EmailRenderer.render_html(
      doc(blocks: [ { "type" => "spacer", "height" => 30 }, { "type" => "text", "text" => "x" } ])
    )

    assert_includes html, "padding:0px 24px"
    assert_includes html, "padding:12px 24px"
    assert_includes html, "height:30px"
  end

  # ── rich twin compilation ─────────────────────────────────────────────────

  test "font class tokens compile to the BRAND_FONTS stack inline" do
    html = Comms::EmailRenderer.render_html(
      doc(blocks: [ { "type" => "text", "text" => "Fancy word",
                      "text_html" => %(Fancy <span class="font-lora">word</span>) } ])
    )

    assert_includes html, "font-family:'Lora', serif"
    assert_not_includes html, "font-lora"
  end

  test "size tokens resolve against the block's base size" do
    text = Comms::EmailRenderer.render_html(
      doc(blocks: [ { "type" => "text", "text" => "Big word",
                      "text_html" => %(Big <span class="size-l">word</span>) } ])
    )
    heading = Comms::EmailRenderer.render_html(
      doc(blocks: [ { "type" => "heading", "text" => "Big word", "level" => 1,
                      "text_html" => %(Big <span class="size-l">word</span>) } ])
    )

    assert_includes text, "font-size:20px"     # 16 * 1.25
    assert_includes heading, "font-size:35px"  # 28 * 1.25
  end

  test "links in rich twins take the document link color and open in new tabs" do
    html = Comms::EmailRenderer.render_html(
      doc(settings: { "linkColor" => "#123456" },
          blocks: [ { "type" => "text", "text" => "Go here",
                      "text_html" => %(Go <a href="https://x.com">here</a>) } ])
    )

    assert_includes html, %(color:#123456)
    assert_includes html, %(target="_blank")
  end

  test "a drifted twin falls back to the escaped plain text at render time" do
    raw = { "version" => 1,
            "blocks" => [ { "id" => "b_1", "type" => "text", "text" => "Real text",
                            "text_html" => "<b>Forged</b>" } ] }
    html = Comms::EmailRenderer.render_html(Comms::EmailDocument.coerce(raw))

    assert_includes html, "Real text"
    assert_not_includes html, "Forged"
  end

  # ── plain text sibling ────────────────────────────────────────────────────

  test "render_text keeps order, links and the unsubscribe line" do
    text = Comms::EmailRenderer.render_text(
      doc(blocks: [
            { "type" => "heading", "text" => "Title" },
            { "type" => "button", "text" => "Go", "href" => "https://x.com" },
            { "type" => "image", "src" => "/x.png", "alt" => "A chart" },
            { "type" => "divider" }
          ])
    )

    assert_includes text, "Title"
    assert_includes text, "Go: https://x.com"
    assert_includes text, "[A chart]"
    assert_includes text, "Unsubscribe: {{unsubscribe_url}}"
    assert_operator text.index("Title"), :<, text.index("Go:")
  end

  test "footer carries business name and postal address in both parts" do
    html = Comms::EmailRenderer.render_html(doc, footer_business: "Playverto",
                                                 footer_address: "1 Verto Way\nLondon")
    text = Comms::EmailRenderer.render_text(doc, footer_business: "Playverto",
                                                 footer_address: "1 Verto Way\nLondon")

    assert_includes html, "1 Verto Way<br>London"
    assert_includes text, "1 Verto Way\nLondon"
    assert_includes html, "Playverto"
  end
end
