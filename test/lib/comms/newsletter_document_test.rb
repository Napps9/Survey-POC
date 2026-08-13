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

  test "blocks run in reading order: intro, features, projects, CTA, sign-off" do
    blocks = build["blocks"]
    headings = blocks.select { |b| b["type"] == "heading" }.map { |b| b["text"] }

    assert_equal COPY["subject"], headings.first
    assert_includes headings, "New this week"
    assert_includes headings, Comms::NewsletterDocument::PROJECTS_HEADING
    assert_includes headings, "Imports keep their columns straight"

    # The projects placeholder sits after the feature items and before the CTA.
    texts = blocks.map { |b| b["text"].to_s }
    projects_at = texts.index(Comms::NewsletterDocument::PROJECTS_PLACEHOLDER)
    feature_at  = texts.index("Imports keep their columns straight")
    button_at   = blocks.index { |b| b["type"] == "button" }
    assert projects_at, "projects placeholder present"
    assert_operator feature_at, :<, projects_at
    assert_operator projects_at, :<, button_at
  end

  test "an item with no body emits only its heading" do
    bodies = build["blocks"].select { |b| b["type"] == "text" }.map { |b| b["text"] }
    assert_not_includes bodies, ""
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
    assert_includes headings, Comms::NewsletterDocument::PROJECTS_HEADING
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
