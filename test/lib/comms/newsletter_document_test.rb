require "test_helper"

# The document must be freezable as generated — EmailDocument.warnings is the
# send gate, and a generated draft the owner cannot send is worthless.
class CommsNewsletterDocumentTest < ActiveSupport::TestCase
  COPY = {
    "subject"   => "Three things that got easier this week",
    "preheader" => "Shorter imports, clearer results.",
    "intro"     => "Here's what changed.",
    "items"     => [
      { "title" => "Imports keep their columns straight", "body" => "No more re-checking." },
      { "title" => "A title with no body", "body" => "" }
    ],
    "cta_label" => "Build your next Verto",
    "sign_off"  => "Tell us what you'd like next."
  }.freeze

  def build(copy = COPY, **kwargs)
    Comms::NewsletterDocument.build(copy, **kwargs)
  end

  def block_of(doc, type)
    doc["blocks"].find { |b| b["type"] == type }
  end

  test "the document coerces cleanly and raises no send warnings" do
    doc = build
    assert_equal [], Comms::EmailDocument.warnings(doc)
    # Survives the model's own sanitize pass unchanged in shape.
    assert_equal doc["blocks"].size, Comms::EmailDocument.coerce(doc)["blocks"].size
  end

  test "blocks run in reading order: masthead, intro, features, projects, CTA, sign-off" do
    blocks = build["blocks"]

    assert_equal "masthead", blocks.first["type"], "the brand band opens the email"
    headings = blocks.select { |b| b["type"] == "heading" }.map { |b| b["text"] }
    assert_equal COPY["subject"], headings.first
    assert_includes headings, "New this week"

    features = blocks.select { |b| b["type"] == "feature" }
    assert_equal [ "Imports keep their columns straight", "A title with no body" ],
                 features.map { |b| b["text"] }
    assert_equal "No more re-checking.", features.first["body"]

    callout = blocks.find { |b| b["type"] == "callout" }
    assert_equal Comms::NewsletterDocument::PROJECTS_HEADING, callout["eyebrow"]
    assert_equal Comms::NewsletterDocument::PROJECTS_PLACEHOLDER, callout["text"]

    # Projects sits after the news and before the CTA.
    assert_operator blocks.index(features.first), :<, blocks.index(callout)
    assert_operator blocks.index(callout), :<, blocks.index { |b| b["type"] == "button" }
  end

  test "the masthead carries the logo, the week and a link, on the brand colour" do
    masthead = block_of(build(COPY, week: Date.new(2026, 8, 10)), "masthead")

    assert_includes masthead["src"], "playverto-email"
    assert_equal "Week of 10 August 2026", masthead["eyebrow"]
    assert masthead["href"].start_with?("http")
    assert_equal BrandPalette::DEFAULT["bg"], masthead["backgroundColor"]
    # The wordmark is white on navy, so the text colour has to follow the band.
    assert_equal "#FFFFFF", masthead["textColor"]
  end

  test "an item with no body leaves the feature's body empty rather than emitting a blank block" do
    features = build["blocks"].select { |b| b["type"] == "feature" }
    assert_equal "", features.last["body"]
    assert_equal [], Comms::EmailDocument.warnings(build)
  end

  test "the CTA button carries a real absolute href" do
    button = block_of(build(COPY, cta_url: "https://app.example.com/surveys"), "button")
    assert_equal "https://app.example.com/surveys", button["href"]
    assert_equal "Build your next Verto", button["text"]
  end

  test "the CTA falls back to a real URL when no host is configured" do
    button = block_of(build, "button")
    assert button["href"].start_with?("http"), "never the placeholder https://"
    assert_not_equal "https://", button["href"]
    assert_equal [], Comms::EmailDocument.warnings(build)
  end

  test "a week with no feature items still produces a sendable document" do
    doc = build(COPY.merge("items" => []))
    assert_equal [], Comms::EmailDocument.warnings(doc)
    headings = doc["blocks"].select { |b| b["type"] == "heading" }.map { |b| b["text"] }
    assert_not_includes headings, "New this week"
    assert_empty doc["blocks"].select { |b| b["type"] == "feature" }
    assert block_of(doc, "callout"), "Projects still needs filling in on a quiet week"
    assert block_of(doc, "masthead")
  end

  test "no image blocks are emitted — a blank src would block the send" do
    assert_empty build["blocks"].select { |b| b["type"] == "image" }
  end

  test "settings come from the brand palette" do
    doc = build(COPY, brand: { "primary" => "#123456" })
    assert_equal "#123456", doc["settings"]["linkColor"]
    assert_equal 600, doc["settings"]["contentWidth"]
  end
end
