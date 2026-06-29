require "test_helper"

class SurveyImageSanitizeTest < ActiveSupport::TestCase
  DATA_URL   = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/1eVAAAAAElFTkSuQmCC"
  ASSET_PATH = "/assets/verto-library/backgrounds/nature.jpg"
  PEXELS_URL = "https://images.pexels.com/photos/123/pexels-photo-123.jpeg?auto=compress&cs=tinysrgb&w=1200&h=627&fit=crop"

  test "sanitize_image_url accepts data-URLs, asset paths and Pexels URLs" do
    assert_equal DATA_URL,   Survey.sanitize_image_url(DATA_URL)
    assert_equal ASSET_PATH, Survey.sanitize_image_url(ASSET_PATH)
    assert_equal PEXELS_URL, Survey.sanitize_image_url(PEXELS_URL)
  end

  test "sanitize_image_url rejects other hosts and CSS-breaking input" do
    assert_nil Survey.sanitize_image_url("https://evil.example.com/x.jpg")
    assert_nil Survey.sanitize_image_url("https://images.pexels.com/x.jpg');background:url('http://evil")
    assert_nil Survey.sanitize_image_url("javascript:alert(1)")
    assert_nil Survey.sanitize_image_url("")
    assert_nil Survey.sanitize_image_url(nil)
  end

  test "sanitize_background_image delegates to sanitize_image_url" do
    assert_equal PEXELS_URL, Survey.sanitize_background_image(PEXELS_URL)
    assert_nil Survey.sanitize_background_image("https://evil.example.com/x.jpg")
  end

  test "sanitize_cards_images! scrubs image and option_images, leaves other fields" do
    cards = [
      { "type" => "multiple_choice", "text" => "Q", "image" => PEXELS_URL },
      { "type" => "multiple_choice", "text" => "Q", "image" => "https://evil.example.com/x.jpg" },
      { "type" => "tap_card", "text" => "Swipe",
        "option_images" => [ PEXELS_URL, "https://evil.example.com/x.jpg" ] }
    ]
    out = Survey.sanitize_cards_images!(cards)

    assert_equal PEXELS_URL, out[0]["image"]
    assert_equal "Q", out[0]["text"]
    assert_nil out[1]["image"]
    assert_equal [ PEXELS_URL, nil ], out[2]["option_images"]
  end
end
