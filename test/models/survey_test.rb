require "test_helper"

class SurveyTest < ActiveSupport::TestCase
  # ── sanitize_background_image ──────────────────────────────────────────────

  test "accepts an app-rooted asset image path" do
    path = "/assets/verto-library/backgrounds/landscape.jpg"
    assert_equal path, Survey.sanitize_background_image(path)
  end

  test "accepts a small base64 data-image URL" do
    url = "data:image/webp;base64,#{Base64.strict_encode64("small")}"
    assert_equal url, Survey.sanitize_background_image(url)
  end

  test "rejects an oversized base64 data-image URL" do
    blob = "A" * (Survey::MAX_BACKGROUND_DATA_URL_BYTES + 1)
    url  = "data:image/jpeg;base64,#{blob}"
    assert_nil Survey.sanitize_background_image(url)
  end

  test "rejects a non-image value" do
    assert_nil Survey.sanitize_background_image("https://evil.example/x.png")
    assert_nil Survey.sanitize_background_image("javascript:alert(1)")
  end

  test "treats blank as no background" do
    assert_nil Survey.sanitize_background_image("")
    assert_nil Survey.sanitize_background_image(nil)
    assert_nil Survey.sanitize_background_image("   ")
  end
end
