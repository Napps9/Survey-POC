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

  # A real Active Storage blob path (org brand-asset library): signed id with
  # base64 padding + `--` separator, and a URL-encoded filename.
  BLOB_URL = "/rails/active_storage/blobs/redirect/eyJfcmFpbHMiOnsiZGF0YSI6MX19==--6b887ab3d44f50c2/logo%20mark.png"

  test "sanitize_image_url accepts same-origin Active Storage image URLs" do
    assert_equal BLOB_URL, Survey.sanitize_image_url(BLOB_URL)
    assert_equal "/rails/active_storage/blobs/x.webp",
                 Survey.sanitize_image_url("/rails/active_storage/blobs/x.webp")
  end

  test "sanitize_image_url rejects other hosts and CSS-breaking input" do
    assert_nil Survey.sanitize_image_url("https://evil.example.com/x.jpg")
    assert_nil Survey.sanitize_image_url("https://images.pexels.com/x.jpg');background:url('http://evil")
    assert_nil Survey.sanitize_image_url("javascript:alert(1)")
    assert_nil Survey.sanitize_image_url("")
    assert_nil Survey.sanitize_image_url(nil)
    # Active Storage path must stay an IMAGE and can't break out of url('…').
    assert_nil Survey.sanitize_image_url("/rails/active_storage/blobs/redirect/abc/evil.svgx")
    assert_nil Survey.sanitize_image_url("/rails/active_storage/blobs/x.png');background:url('http://evil")
    # A cross-origin URL that merely contains the AS path must not pass.
    assert_nil Survey.sanitize_image_url("https://evil.com/rails/active_storage/blobs/x.png")
  end

  test "sanitize_image_url rejects a data-URL over the byte cap" do
    oversized = "data:image/png;base64,#{"A" * (Survey::MAX_BACKGROUND_DATA_URL_BYTES + 1)}"
    assert_nil Survey.sanitize_image_url(oversized)
  end

  test "sanitize_background_image delegates to sanitize_image_url" do
    assert_equal PEXELS_URL, Survey.sanitize_background_image(PEXELS_URL)
    assert_nil Survey.sanitize_background_image("https://evil.example.com/x.jpg")
  end

  test "sanitize_cards_images! de-dupes shared cids and backfills missing ones" do
    cards = [
      { "type" => "multiple_choice", "text" => "A", "cid" => "c_dup" },
      { "type" => "multiple_choice", "text" => "B", "cid" => "c_dup" }, # collision
      { "type" => "multiple_choice", "text" => "C" }                     # missing
    ]
    cids = Survey.sanitize_cards_images!(cards).map { |c| c["cid"] }

    assert_equal cids.size, cids.uniq.size, "every card must end with a unique cid"
    assert_equal "c_dup", cids[0], "the first occurrence keeps its cid (existing routes still resolve)"
    refute_equal "c_dup", cids[1], "the duplicate is reassigned a fresh cid"
    assert cids[2].present?, "a missing cid is backfilled"
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

  test "sanitize_cards_images! with warnings: reports only fields that were present and got dropped" do
    oversized = "data:image/png;base64,#{"A" * (Survey::MAX_BACKGROUND_DATA_URL_BYTES + 1)}"
    cards = [
      { "type" => "multiple_choice", "text" => "Q", "image" => oversized },
      { "type" => "tap_card", "text" => "Swipe", "option_images" => [ PEXELS_URL, oversized ] },
      { "type" => "multiple_choice", "text" => "Q", "image" => PEXELS_URL }, # valid — no warning
      { "type" => "multiple_choice", "text" => "Q", "image" => "" }         # already blank — no warning
    ]
    warnings = []
    out = Survey.sanitize_cards_images!(cards, warnings: warnings)

    assert_nil out[0]["image"]
    assert_equal [ PEXELS_URL, nil ], out[1]["option_images"]
    assert_equal %w[image option_images], warnings.sort
  end

  test "sanitize_cards_images! defaults to not tracking warnings" do
    oversized = "data:image/png;base64,#{"A" * (Survey::MAX_BACKGROUND_DATA_URL_BYTES + 1)}"
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => oversized } ]
    out = Survey.sanitize_cards_images!(cards) # no warnings: kwarg — must not raise

    assert_nil out[0]["image"]
  end

  test "sanitize_cards_images! whitelists range_theme on range cards and drops the rest" do
    cards = [
      { "type" => "range", "text" => "Q", "range_theme" => "football" },
      { "type" => "range", "text" => "Q", "range_theme" => "basketball" },
      { "type" => "range", "text" => "Q", "range_theme" => "not_a_theme" },
      { "type" => "multiple_choice", "text" => "Q", "range_theme" => "football" }
    ]
    out = Survey.sanitize_cards_images!(cards)

    assert_equal "football", out[0]["range_theme"]
    assert_equal "basketball", out[1]["range_theme"]
    assert_nil out[2]["range_theme"], "unknown theme slug is dropped"
    assert_nil out[3]["range_theme"], "range_theme is only kept on range cards"
  end

  test "sanitize_cards_images! whitelists demographic_key on demographic cards and drops the rest" do
    cards = [
      { "type" => "multiple_choice", "text" => "Q", "demographic" => true, "demographic_key" => "heritage" },
      { "type" => "select_many", "text" => "Q", "demographic" => true, "demographic_key" => "neurodiversity" },
      { "type" => "multiple_choice", "text" => "Q", "demographic" => true, "demographic_key" => "astrology" },
      { "type" => "multiple_choice", "text" => "Q", "demographic_key" => "heritage" }
    ]
    out = Survey.sanitize_cards_images!(cards)

    assert_equal "heritage", out[0]["demographic_key"]
    assert_equal "neurodiversity", out[1]["demographic_key"]
    assert_nil out[2]["demographic_key"], "unknown key is dropped"
    assert_nil out[3]["demographic_key"],
               "a key without the demographic flag is dropped — the flag is what buys " \
               "consent gating and imagery suppression, so a key can't ride without it"
  end

  test "sanitize_cards_images! whitelists slider_axis on range cards and drops the rest" do
    cards = [
      { "type" => "range", "text" => "Q", "slider_axis" => "horizontal" },
      { "type" => "range", "text" => "Q", "slider_axis" => "vertical" },
      { "type" => "range", "text" => "Q", "slider_axis" => "auto" },
      { "type" => "range", "text" => "Q", "slider_axis" => "diagonal" },
      { "type" => "multiple_choice", "text" => "Q", "slider_axis" => "vertical" }
    ]
    out = Survey.sanitize_cards_images!(cards)

    assert_equal "horizontal", out[0]["slider_axis"]
    assert_equal "vertical", out[1]["slider_axis"]
    assert_equal "auto", out[2]["slider_axis"]
    assert_nil out[3]["slider_axis"], "unknown axis value is dropped"
    assert_nil out[4]["slider_axis"], "slider_axis is only kept on range cards"
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
