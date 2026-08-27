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

  test "sanitize_cards_images! keeps animate_asset on a card with a photo or a lottie" do
    cards = [
      { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH, "animate_asset" => true },
      { "type" => "open_ended", "text" => "Q2", "lottie" => LOTTIE_BLOB_URL, "animate_asset" => true }
    ]
    out = Survey.sanitize_cards_images!(cards)

    assert_equal true, out[0]["animate_asset"]
    assert_equal true, out[1]["animate_asset"]
  end

  test "sanitize_cards_images! drops animate_asset on video, range, and a card with no media" do
    cards = [
      { "type" => "multiple_choice", "text" => "Q", "video" => "https://videos.pexels.com/x/clip.mp4", "animate_asset" => true },
      { "type" => "range", "text" => "Q2", "options" => %w[1 2 3], "animate_asset" => true },
      { "type" => "multiple_choice", "text" => "Q3", "animate_asset" => true }
    ]
    out = Survey.sanitize_cards_images!(cards)

    refute out[0].key?("animate_asset"), "video has its own motion already"
    refute out[1].key?("animate_asset"), "range already animates via its reaction set"
    refute out[2].key?("animate_asset"), "nothing to animate without a photo or lottie"
  end

  test "sanitize_cards_images! drops animate_asset when the image it referred to is rejected" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => "not a real url", "animate_asset" => true } ]
    out = Survey.sanitize_cards_images!(cards).first

    assert_nil out["image"]
    refute out.key?("animate_asset")
  end

  test "sanitize_cards_images! warns when an animation silently drops a stored photo or video" do
    # A card should never reach this state (both `image` and `lottie` set) —
    # the client enforces the same exclusivity, and every writer is meant to
    # go through this sanitiser. It happened anyway once (a Shuffle bug,
    # fixed separately): whatever put a card here deserves a visible warning
    # instead of a silent drop, same as an outright-rejected image would get.
    warnings = []
    cards = [ { "type" => "multiple_choice", "text" => "Q",
                "lottie" => LOTTIE_BLOB_URL, "image" => ASSET_PATH,
                "video" => "https://videos.pexels.com/x/clip.mp4" } ]
    out = Survey.sanitize_cards_images!(cards, warnings: warnings).first

    refute out.key?("image")
    refute out.key?("video")
    assert_includes warnings, "image"
    assert_includes warnings, "video"
  end

  test "sanitize_cards_images! does not warn when an animation has no photo or video to drop" do
    warnings = []
    cards = [ { "type" => "multiple_choice", "text" => "Q", "lottie" => LOTTIE_BLOB_URL } ]
    Survey.sanitize_cards_images!(cards, warnings: warnings)

    assert_empty warnings
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

  # ── The horizontal axis, and video (reposition, not crop) ──────────────
  # "I need the ability in the editor to reposition every image and piece of
  # content — at the moment I can only do it with uploads." The crop stage can
  # only redraw a same-origin still, so a Pexels photo and a video had no
  # reframing at all. A stored position has no such limit, which is why it is
  # the axis that got widened rather than the crop.

  test "focal_x is kept alongside focal_y on a card with an image" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH,
                "focal_x" => 20, "focal_y" => 80 } ]
    out = Survey.sanitize_cards_images!(cards).first
    assert_equal 20, out["focal_x"]
    assert_equal 80, out["focal_y"]
  end

  test "focal_x is clamped and rounded like focal_y" do
    [ [ -40, 0 ], [ 33.4, 33 ], [ 180, 100 ] ].each do |given, want|
      cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH, "focal_x" => given } ]
      assert_equal want, Survey.sanitize_cards_images!(cards).first["focal_x"],
                   "focal_x #{given.inspect} should clamp to #{want}"
    end
  end

  test "a centred or junk focal_x is dropped rather than stored" do
    [ 50, "left; background:url(evil)", nil ].each do |given|
      cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH, "focal_x" => given } ]
      refute Survey.sanitize_cards_images!(cards).first.key?("focal_x"),
             "focal_x #{given.inspect} should not be stored"
    end
  end

  # A Pexels photo is exactly the case the crop stage cannot serve — drawing it
  # on a canvas taints the canvas — so it is the case a reposition has to.
  test "a focal point survives on a card whose image is a remote Pexels URL" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => PEXELS_URL,
                "focal_x" => 25, "focal_y" => 75 } ]
    out = Survey.sanitize_cards_images!(cards).first
    assert_equal 25, out["focal_x"]
    assert_equal 75, out["focal_y"]
  end

  test "a focal point is kept on a video card, which can be moved but never cropped" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "video" => VIDEO_URL,
                "focal_x" => 30, "focal_y" => 10 } ]
    out = Survey.sanitize_cards_images!(cards).first
    assert_equal 30, out["focal_x"]
    assert_equal 10, out["focal_y"]
  end

  test "a focal point dies with the media it describes" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "video" => "https://evil.example.com/x.mp4",
                "focal_x" => 30, "focal_y" => 10 } ]
    out = Survey.sanitize_cards_images!(cards).first
    refute out.key?("focal_x"), "a rejected video leaves nothing to position"
    refute out.key?("focal_y")
  end

  # ── Per-statement repositions (option_focals) ──────────────────────────
  # Positional against option_images, exactly like the images themselves.

  test "option_focals keeps a moved statement and nils the rest" do
    cards = [ { "type" => "tap_card", "text" => "Q", "options" => %w[a b],
                "option_images" => [ ASSET_PATH, PEXELS_URL ],
                "option_focals" => [ nil, { "x" => 20, "y" => 90 } ] } ]
    assert_equal [ nil, { "x" => 20, "y" => 90 } ],
                 Survey.sanitize_cards_images!(cards).first["option_focals"]
  end

  test "option_focals fills in a missing axis rather than dropping the pair" do
    cards = [ { "type" => "tap_card", "text" => "Q", "options" => %w[a],
                "option_images" => [ ASSET_PATH ], "option_focals" => [ { "y" => 12 } ] } ]
    assert_equal [ { "x" => 50, "y" => 12 } ],
                 Survey.sanitize_cards_images!(cards).first["option_focals"]
  end

  test "option_focals is bounded by the images it positions" do
    cards = [ { "type" => "tap_card", "text" => "Q", "options" => %w[a b],
                "option_images" => [ ASSET_PATH, "" ],
                "option_focals" => [ { "x" => 10, "y" => 10 }, { "x" => 90, "y" => 90 }, { "x" => 5, "y" => 5 } ] } ]
    assert_equal [ { "x" => 10, "y" => 10 } ],
                 Survey.sanitize_cards_images!(cards).first["option_focals"],
                 "a slot with no picture, and a slot past the end, can't carry a position"
  end

  test "an all-centre or junk option_focals is dropped rather than stored" do
    [ [ { "x" => 50, "y" => 50 } ], [ nil ], [ "50% 50%" ], "left", nil ].each do |given|
      cards = [ { "type" => "tap_card", "text" => "Q", "options" => %w[a],
                  "option_images" => [ ASSET_PATH ], "option_focals" => given } ]
      refute Survey.sanitize_cards_images!(cards).first.key?("option_focals"),
             "option_focals #{given.inspect} says nothing and should not be stored"
    end
  end

  # ── Zoom (focal_zoom) ─────────────────────────────────────────────────
  # A picture whose shape already matches the frame hides nothing on that axis,
  # so a drag there has nothing to reveal — "we need to be able to reposition
  # vertical as well as horizontally". Punching in past cover-fit is what buys
  # the slack, and like the focal point it re-encodes nothing.

  test "focal_zoom is kept, clamped and rounded" do
    [ [ 1.5, 1.5 ], [ "2.25", 2.25 ], [ 0.2, nil ], [ 9, 3.0 ], [ 1, nil ], [ "wide", nil ] ].each do |given, want|
      cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH, "focal_zoom" => given } ]
      out = Survey.sanitize_cards_images!(cards).first
      if want
        assert_equal want, out["focal_zoom"], "focal_zoom #{given.inspect} should land on #{want}"
      else
        refute out.key?("focal_zoom"), "focal_zoom #{given.inspect} says nothing and should not be stored"
      end
    end
  end

  test "focal_zoom stands alone — a card can punch in without moving off centre" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "image" => ASSET_PATH,
                "focal_x" => 50, "focal_y" => 50, "focal_zoom" => 1.8 } ]
    out = Survey.sanitize_cards_images!(cards).first
    assert_equal 1.8, out["focal_zoom"]
    refute out.key?("focal_x"), "centre is still centre — only the zoom was set"
    refute out.key?("focal_y")
  end

  test "focal_zoom dies with the media it magnifies" do
    cards = [ { "type" => "multiple_choice", "text" => "Q", "focal_zoom" => 2 } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("focal_zoom")
  end

  test "a statement's zoom rides in its own slot" do
    cards = [ { "type" => "tap_card", "text" => "Q", "options" => %w[a b],
                "option_images" => [ ASSET_PATH, ASSET_PATH ],
                "option_focals" => [ { "x" => 20, "y" => 30, "z" => 1.4 }, { "z" => 2 } ] } ]
    assert_equal [ { "x" => 20, "y" => 30, "z" => 1.4 }, { "x" => 50, "y" => 50, "z" => 2.0 } ],
                 Survey.sanitize_cards_images!(cards).first["option_focals"],
                 "a zoomed-but-centred statement is still a reframing and must survive"
  end

  test "a statement centred at cover-fit is stored as nothing" do
    cards = [ { "type" => "tap_card", "text" => "Q", "options" => %w[a],
                "option_images" => [ ASSET_PATH ],
                "option_focals" => [ { "x" => 50, "y" => 50, "z" => 1 } ] } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("option_focals")
  end

  test "option_focals dies with the images it positions" do
    cards = [ { "type" => "tap_card", "text" => "Q", "options" => %w[a],
                "option_images" => [ "https://evil.example.com/x.jpg" ],
                "option_focals" => [ { "x" => 10, "y" => 10 } ] } ]
    refute Survey.sanitize_cards_images!(cards).first.key?("option_focals")
  end
end
