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

  # Uploaders name a blob so its path will pass ACTIVE_STORAGE_IMAGE_URL, and
  # they ask Survey.image_extension? rather than re-listing the extensions. The
  # two must therefore agree about every extension, in both directions.
  test "image_extension? agrees with what sanitize_image_url accepts on a blob path" do
    Survey::IMAGE_EXTENSIONS.each do |ext|
      name = "brand-asset.#{ext}"
      assert Survey.image_extension?(name), "#{ext} should be a storable extension"
      path = "/rails/active_storage/blobs/redirect/eyJfcmFpbHMi--abc123/#{name}"
      assert_equal path, Survey.sanitize_image_url(path), "#{ext} blob path should survive"
    end
  end

  test "image_extension? rejects names that would be dropped from a card" do
    # Valid images by content type, unusable as a blob path: the branding page
    # accepted these and the card sanitiser then dropped them, which is what
    # produced "an image didn't stick" however often the creator re-uploaded.
    [ "company-logo", "holiday.jfif", "scan.jpe", "chart.bmp", "" ].each do |name|
      assert_not Survey.image_extension?(name), "#{name.inspect} should not be storable as-is"
      assert_nil Survey.sanitize_image_url("/rails/active_storage/blobs/redirect/eyJfcmFpbHMi--abc123/#{name}")
    end
    assert_not Survey.image_extension?(nil)
  end

  test "image_extension? is case-insensitive, like the sanitiser" do
    assert Survey.image_extension?("Logo.JPG")
    assert Survey.image_extension?("Logo.PNG")
    path = "/rails/active_storage/blobs/redirect/eyJfcmFpbHMi--abc123/Logo.JPG"
    assert_equal path, Survey.sanitize_image_url(path)
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

  # Card animations: only the same-origin stored copy survives — a pasted
  # LottieFiles URL must go through CardLottieStore first, never straight
  # onto the card.
  LOTTIE_BLOB_URL = "/rails/active_storage/blobs/redirect/eyJfcmFpbHMiOnsiZGF0YSI6MX19==--6b887ab3d44f50c2/card-lottie-abc123.json"

  test "sanitize_lottie_url accepts same-origin Active Storage JSON only" do
    assert_equal LOTTIE_BLOB_URL, Survey.sanitize_lottie_url(LOTTIE_BLOB_URL)
    assert_nil Survey.sanitize_lottie_url("https://lottie.host/abc/anim.json"),
               "external URLs never land on a card, allowlisted host or not"
    assert_nil Survey.sanitize_lottie_url("/rails/active_storage/blobs/x.png")
    assert_nil Survey.sanitize_lottie_url("https://evil.com/rails/active_storage/blobs/x.json")
    assert_nil Survey.sanitize_lottie_url("")
  end

  test "sanitize_cards_images! keeps a stored lottie and drops the rest of the media" do
    cards = [ { "type" => "multiple_choice", "text" => "Q",
                "lottie" => LOTTIE_BLOB_URL, "image" => ASSET_PATH,
                "video" => "https://videos.pexels.com/x/clip.mp4", "video_poster" => ASSET_PATH,
                "image_credit" => "Someone", "image_credit_url" => "https://www.pexels.com/@someone" } ]
    out = Survey.sanitize_cards_images!(cards).first

    assert_equal LOTTIE_BLOB_URL, out["lottie"]
    refute out.key?("image"),        "an animation replaces the photo"
    refute out.key?("video"),        "an animation replaces the video"
    refute out.key?("video_poster")
    refute out.key?("image_credit"), "credits belong to photos/videos only"
  end

  test "sanitize_cards_images! drops an external lottie URL with a warning" do
    warnings = []
    cards = [ { "type" => "multiple_choice", "text" => "Q",
                "lottie" => "https://lottie.host/abc/anim.json" } ]
    out = Survey.sanitize_cards_images!(cards, warnings: warnings).first

    refute out.key?("lottie")
    assert_includes warnings, "lottie"
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

  # option_images is POSITIONAL — index i is statement i — so an empty slot is a
  # statement with no picture, not a picture that was dropped. The warning used
  # to be array-wide ("something present" && "something nil"), so a tap card
  # where the creator had cleared one statement's image warned on EVERY autosave
  # and told them to re-upload the image they had just deliberately removed.
  test "sanitize_cards_images! does not warn about option_images slots that were already empty" do
    cards = [
      { "type" => "tap_card", "text" => "Swipe", "option_images" => [ "", "", PEXELS_URL, "" ] },
      { "type" => "tap_card", "text" => "Swipe", "option_images" => [ nil, PEXELS_URL ] },
      { "type" => "tap_card", "text" => "Swipe", "option_images" => [ "", "" ] }
    ]
    warnings = []
    out = Survey.sanitize_cards_images!(cards, warnings: warnings)

    assert_equal [ nil, nil, PEXELS_URL, nil ], out[0]["option_images"], "blank slots still normalise to nil"
    assert_empty warnings, "an empty statement slot is not a dropped image"
  end

  test "sanitize_cards_images! still warns when a present option_image is dropped beside empty slots" do
    oversized = "data:image/png;base64,#{"A" * (Survey::MAX_BACKGROUND_DATA_URL_BYTES + 1)}"
    cards = [ { "type" => "tap_card", "text" => "Swipe",
                "option_images" => [ "", PEXELS_URL, oversized, "" ] } ]
    warnings = []
    out = Survey.sanitize_cards_images!(cards, warnings: warnings)

    assert_equal [ nil, PEXELS_URL, nil, nil ], out[0]["option_images"]
    assert_equal [ "option_images" ], warnings
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

  # ── Animation backdrop (media_bg) ──────────────────────────────────────
  # A per-card colour/image behind a Lottie or a range card's reaction set,
  # overriding the Verto-wide --brand-panel. Allowlist-or-drop, like
  # range_theme: only a real hex and a real image URL survive, and only on a
  # card whose panel actually animates.

  test "media_bg keeps a valid colour on a lottie card" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "lottie" => LOTTIE_BLOB_URL,
                "media_bg" => { "color" => "#FF00AA" } } ]
    out = Survey.sanitize_cards_images!(cards).first
    assert_equal({ "color" => "#ff00aa" }, out["media_bg"],
                 "hex is normalised the way option_styles does it")
  end

  test "media_bg keeps a colour and an image together on a range card" do
    cards = [ { "type" => "range", "text" => "Q", "options" => %w[a b c d e],
                "media_bg" => { "color" => "#123456", "image" => ASSET_PATH } } ]
    out = Survey.sanitize_cards_images!(cards).first
    assert_equal "#123456",   out["media_bg"]["color"]
    assert_equal ASSET_PATH,  out["media_bg"]["image"]
  end

  test "media_bg is dropped on a card whose panel is a photo" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH,
                "media_bg" => { "color" => "#123456" } } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("media_bg"),
           "there is nothing to see behind a photo — the photo covers the panel"
  end

  test "media_bg drops a junk colour and an off-allowlist image" do
    cards = [ { "type" => "range", "text" => "Q", "options" => %w[a b c d e],
                "media_bg" => { "color" => "javascript:alert(1)", "image" => "https://evil.com/x.png" } } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("media_bg"),
           "nothing valid survived, so the key should go rather than persist as {}"
  end

  test "media_bg survives only what it can validate, not the whole hash" do
    cards = [ { "type" => "range", "text" => "Q", "options" => %w[a b c d e],
                "media_bg" => { "color" => "#abcdef", "image" => "https://evil.com/x.png",
                                "onclick" => "boom" } } ]
    out = Survey.sanitize_cards_images!(cards).first
    assert_equal({ "color" => "#abcdef" }, out["media_bg"])
  end

  test "media_bg is dropped when it is not a hash" do
    cards = [ { "type" => "range", "text" => "Q", "options" => %w[a b c d e],
                "media_bg" => "#ff0000" } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("media_bg")
  end

  # ── Mobile header focal point (focal_y) ────────────────────────────────
  # The card image is a 9:16 portrait; the mobile header is a ~3:1 band. `cover`
  # + centre therefore shows only the middle stripe, and a subject near the top
  # of the photo is simply absent on a phone. focal_y records which stripe to
  # show, WITHOUT re-cropping, so the original stays whole and adjustable.

  test "focal_y is kept on a card with an image" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH, "focal_y" => 18 } ]
    assert_equal 18, Survey.sanitize_cards_images!(cards).first["focal_y"]
  end

  test "focal_y is clamped to the percentage range and rounded" do
    [ [ -40, 0 ], [ 0, 0 ], [ 33.4, 33 ], [ 100, 100 ], [ 180, 100 ] ].each do |given, want|
      cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH, "focal_y" => given } ]
      assert_equal want, Survey.sanitize_cards_images!(cards).first["focal_y"],
                   "focal_y #{given.inspect} should clamp to #{want}"
    end
  end

  # Centre is the default everywhere, so storing it is storing nothing.
  test "a centred focal_y is dropped rather than stored" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH, "focal_y" => 50 } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("focal_y")
  end

  test "focal_y is dropped on a card with no image to position" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "focal_y" => 20 } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("focal_y")

    lottie = [ { "type" => "multiple_choice", "text" => "Q",
                 "lottie" => LOTTIE_BLOB_URL, "focal_y" => 20 } ]
    refute Survey.sanitize_cards_images!(lottie).first.key?("focal_y"),
           "an animation fills the panel — there is no crop to reposition"
  end

  test "a junk focal_y is dropped rather than stored" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH,
                "focal_y" => "top; background:url(evil)" } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("focal_y")
  end
end
