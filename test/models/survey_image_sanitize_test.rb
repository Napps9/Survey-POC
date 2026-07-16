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

  VIDEO_URL  = "https://videos.pexels.com/video-files/123/hd.mp4"
  POSTER_URL = "https://images.pexels.com/videos/123/poster.jpeg?auto=compress"

  test "sanitize_video_url accepts the Pexels video CDN and rejects others" do
    assert_equal VIDEO_URL, Survey.sanitize_video_url(VIDEO_URL)
    assert_equal "#{VIDEO_URL}?fps=30", Survey.sanitize_video_url("#{VIDEO_URL}?fps=30")
    assert_nil Survey.sanitize_video_url("https://evil.example.com/x.mp4")
    assert_nil Survey.sanitize_video_url("https://videos.pexels.com/x.exe")
    assert_nil Survey.sanitize_video_url(nil)
  end

  test "sanitize_cards_images! keeps a valid video + poster + credit" do
    cards = [
      { "type" => "multiple_choice", "text" => "Q", "video" => VIDEO_URL, "video_poster" => POSTER_URL,
        "image_credit" => "Sam Reel", "image_credit_url" => "https://www.pexels.com/@sam" },
      { "type" => "multiple_choice", "text" => "Q", "video" => "https://evil.example.com/x.mp4",
        "video_poster" => POSTER_URL, "image_credit" => "Orphan", "image_credit_url" => "https://www.pexels.com/@x" }
    ]
    out = Survey.sanitize_cards_images!(cards)

    assert_equal VIDEO_URL, out[0]["video"]
    assert_equal POSTER_URL, out[0]["video_poster"]
    assert_equal "Sam Reel", out[0]["image_credit"]

    assert_nil out[1]["video"], "non-Pexels video host is rejected"
    assert_nil out[1]["video_poster"], "poster dropped when its video is rejected"
    assert_nil out[1]["image_credit"], "credit cleared when there's no image or video"
  end

  test "sanitize_cards_images! whitelists range_theme on range cards and drops the rest" do
    cards = [
      { "type" => "range", "text" => "Q", "range_theme" => "football" },
      { "type" => "range", "text" => "Q", "range_theme" => "baseball" },
      { "type" => "range", "text" => "Q", "range_theme" => "not_a_theme" },
      { "type" => "multiple_choice", "text" => "Q", "range_theme" => "football" }
    ]
    out = Survey.sanitize_cards_images!(cards)

    assert_equal "football", out[0]["range_theme"]
    assert_equal "baseball", out[1]["range_theme"]
    assert_nil out[2]["range_theme"], "unknown theme slug is dropped"
    assert_nil out[3]["range_theme"], "range_theme is only kept on range cards"
  end

  test "sanitize_credit_url accepts pexels.com profile links and rejects others" do
    assert_equal "https://www.pexels.com/@jane", Survey.sanitize_credit_url("https://www.pexels.com/@jane")
    assert_equal "https://pexels.com/@jane",     Survey.sanitize_credit_url("https://pexels.com/@jane")
    assert_nil Survey.sanitize_credit_url("https://evil.example.com/@jane")
    assert_nil Survey.sanitize_credit_url("javascript:alert(1)")
    assert_nil Survey.sanitize_credit_url(nil)
  end

  test "sanitize_cards_images! keeps a valid credit, drops a bad link, and clears orphans" do
    cards = [
      { "type" => "multiple_choice", "text" => "Q", "image" => PEXELS_URL,
        "image_credit" => "Jane Doe", "image_credit_url" => "https://www.pexels.com/@jane" },
      { "type" => "multiple_choice", "text" => "Q", "image" => PEXELS_URL,
        "image_credit" => "Jane Doe", "image_credit_url" => "https://evil.example.com/@jane" },
      { "type" => "multiple_choice", "text" => "Q", "image" => "https://evil.example.com/x.jpg",
        "image_credit" => "Orphan", "image_credit_url" => "https://www.pexels.com/@x" }
    ]
    out = Survey.sanitize_cards_images!(cards)

    assert_equal "Jane Doe", out[0]["image_credit"]
    assert_equal "https://www.pexels.com/@jane", out[0]["image_credit_url"]

    assert_equal "Jane Doe", out[1]["image_credit"]
    assert_nil out[1]["image_credit_url"], "non-Pexels credit link is dropped (name still shows)"

    assert_nil out[2]["image"]
    assert_nil out[2]["image_credit"], "credit is cleared when the image is rejected"
    assert_nil out[2]["image_credit_url"]
  end
end
