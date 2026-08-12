require "test_helper"

class Comms::EmailDocumentTest < ActiveSupport::TestCase
  # ── coerce ────────────────────────────────────────────────────────────────

  test "junk input coerces to an empty document with default settings" do
    doc = Comms::EmailDocument.coerce("not a hash")

    assert_equal 1, doc["version"]
    assert_equal [], doc["blocks"]
    assert_equal 600, doc["settings"]["contentWidth"]
    assert_equal "#FFFFFF", doc["settings"]["contentBackgroundColor"]
  end

  test "unknown block types are dropped, known ones keep their fields" do
    doc = Comms::EmailDocument.coerce({
      "blocks" => [
        { "type" => "marquee", "text" => "nope" },
        { "type" => "heading", "text" => "Hi", "level" => 3, "align" => "center" },
        "not even a hash"
      ]
    })

    assert_equal 1, doc["blocks"].size
    block = doc["blocks"].first
    assert_equal "heading", block["type"]
    assert_equal 3, block["level"]
    assert_equal "center", block["align"]
    assert block["id"].present?
  end

  test "numeric fields clamp to their ranges" do
    doc = Comms::EmailDocument.coerce({
      "settings" => { "contentWidth" => 9999 },
      "blocks" => [
        { "type" => "image", "src" => "/x.png", "widthPct" => 400 },
        { "type" => "spacer", "height" => 2 },
        { "type" => "heading", "text" => "H", "level" => 7 }
      ]
    })

    assert_equal 800, doc["settings"]["contentWidth"]
    assert_equal 100, doc["blocks"][0]["widthPct"]
    assert_equal 4, doc["blocks"][1]["height"]
    assert_equal 2, doc["blocks"][2]["level"]
  end

  test "malformed align and headingTransform fall back" do
    doc = Comms::EmailDocument.coerce({
      "settings" => { "headingTransform" => "blink" },
      "blocks" => [ { "type" => "text", "text" => "T", "align" => "justify" } ]
    })

    assert_equal "none", doc["settings"]["headingTransform"]
    assert_equal "left", doc["blocks"][0]["align"]
  end

  # ── sanitize (the save gate) ──────────────────────────────────────────────

  test "sanitize keeps an html twin that matches its plain text" do
    doc = Comms::EmailDocument.sanitize({
      "blocks" => [ { "type" => "text", "text" => "Hello friend",
                      "text_html" => "Hello <b>friend</b>" } ]
    })

    assert_equal "Hello <b>friend</b>", doc["blocks"][0]["text_html"]
  end

  test "sanitize drops an html twin whose visible text drifted" do
    doc = Comms::EmailDocument.sanitize({
      "blocks" => [ { "type" => "text", "text" => "Hello friend",
                      "text_html" => "Goodbye <b>stranger</b>" } ]
    })

    assert_not doc["blocks"][0].key?("text_html")
  end

  test "sanitize keeps email links but strips script vectors" do
    doc = Comms::EmailDocument.sanitize({
      "blocks" => [ { "type" => "text", "text" => "Go here now",
                      "text_html" => %(Go <a href="https://x.com">here</a> <a href="javascript:alert(1)">now</a>) } ]
    })

    html = doc["blocks"][0]["text_html"]
    assert_includes html, %(<a href="https://x.com">here</a>)
    assert_not_includes html, "javascript:"
    assert_includes html, "now"
  end

  # ── warnings ──────────────────────────────────────────────────────────────

  test "warnings gate: empty doc, srcless image, linkless button" do
    empty = Comms::EmailDocument.coerce({})
    assert_includes Comms::EmailDocument.warnings(empty).join, "no content blocks"

    doc = Comms::EmailDocument.coerce({
      "blocks" => [
        { "type" => "image", "src" => "" },
        { "type" => "button", "text" => "Go", "href" => "https://" }
      ]
    })
    warnings = Comms::EmailDocument.warnings(doc)
    assert_equal 2, warnings.size
  end

  test "a complete document has no warnings" do
    doc = Comms::EmailDocument.coerce({
      "blocks" => [
        { "type" => "heading", "text" => "Hi" },
        { "type" => "button", "text" => "Go", "href" => "https://example.com" }
      ]
    })

    assert_empty Comms::EmailDocument.warnings(doc)
  end

  # ── starter document ──────────────────────────────────────────────────────

  test "starter document seeds heading, text and button; logo only when given" do
    doc = Comms::EmailDocument.starter_document
    assert_equal %w[heading text button], doc["blocks"].map { |b| b["type"] }

    with_logo = Comms::EmailDocument.starter_document(logo_url: "/logo.png")
    assert_equal %w[image heading text button], with_logo["blocks"].map { |b| b["type"] }
    assert_equal 35, with_logo["blocks"][0]["widthPct"]
  end

  test "starter button colors come from the brand palette with readable text" do
    doc = Comms::EmailDocument.starter_document(brand: { "cta" => "#ffffff" })
    button = doc["blocks"].find { |b| b["type"] == "button" }

    assert_equal "#ffffff", button["backgroundColor"]
    assert_equal "#1C2034", button["textColor"]
  end
end
