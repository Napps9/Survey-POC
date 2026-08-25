require "test_helper"

# The re-crop record (Feedback 17: "ability to edit the crop/zoom of an
# image after uploading" — today you must remove and re-upload). The editor
# stores, alongside a cropped upload, the pre-crop original (image_source)
# and where the crop sits in it (image_crop, fractions of the source's
# natural size) — what "Adjust crop" reopens so a creator can zoom back OUT.
#
# Server-side the record is metadata riding sanitize_cards_images!: a source
# without its image is dead data, a crop without its source describes
# nothing, and a rect that isn't four sane fractions is a value we don't
# understand — all dropped rather than kept.
class SurveysImageCropRecordTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(name: "U", email_address: "ic-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org  = Organisation.create!(name: "O", slug: "ic-#{SecureRandom.hex(2)}")
    @org.memberships.create!(user: @user, role: "admin")
    post session_path, params: { email_address: @user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?

    @survey = @org.surveys.create!(
      title: "S", theme: "Space", audience_age: "all", key_insight: "k",
      default_locale: "en", locales: [ "en" ], cards: []
    )
  end

  IMAGE  = "/uploads/crop-final.png"
  SOURCE = "/uploads/crop-original.png"
  CROP   = { "x" => 0.1, "y" => 0.2, "w" => 0.5, "h" => 0.6 }.freeze

  def patch_cards(cards)
    patch survey_path(@survey), params: { cards: cards }.to_json,
          headers: { "Content-Type" => "application/json" }
    assert_response :success
    @survey.reload.cards.first
  end

  # ── sanitize_image_crop itself ────────────────────────────────────────────

  test "sanitize_image_crop keeps a sane rect, rounded" do
    assert_equal({ "x" => 0.1235, "y" => 0.0, "w" => 0.5, "h" => 1.0 },
                 Survey.sanitize_image_crop({ "x" => 0.12345, "y" => 0, "w" => "0.5", "h" => 1 }))
  end

  test "sanitize_image_crop clamps stray fractions instead of trusting them" do
    rect = Survey.sanitize_image_crop({ "x" => -0.2, "y" => 1.5, "w" => 0.4, "h" => 2 })
    assert_equal({ "x" => 0.0, "y" => 1.0, "w" => 0.4, "h" => 1.0 }, rect)
  end

  test "sanitize_image_crop rejects what it cannot read as a rect" do
    # Junk must come back nil — the caller drops the key — never quietly
    # become 0.0 and crop the corner (the focal_y lesson).
    assert_nil Survey.sanitize_image_crop(nil)
    assert_nil Survey.sanitize_image_crop("0.1,0.2,0.5,0.6")
    assert_nil Survey.sanitize_image_crop({ "x" => 0.1, "y" => 0.2, "w" => 0.5 })
    assert_nil Survey.sanitize_image_crop({ "x" => 0.1, "y" => 0.2, "w" => "half", "h" => 0.6 })
    assert_nil Survey.sanitize_image_crop({ "x" => 0.1, "y" => 0.2, "w" => 0, "h" => 0.6 }),
               "a zero-width rect has no area to re-crop"
    assert_nil Survey.sanitize_image_crop({ "x" => 0.1, "y" => 0.2, "w" => -3, "h" => 0.6 }),
               "negative extent clamps to zero area and must reject, not survive as 0.0"
  end

  # ── the record through an editor PATCH ────────────────────────────────────

  test "a card image keeps its source and crop through a save" do
    card = patch_cards([ { type: "multiple_choice", text: "Q", options: [ "A" ],
                           image: IMAGE, image_source: SOURCE, image_crop: CROP } ])

    assert_equal SOURCE, card["image_source"],
                 "the pre-crop original was dropped — Adjust crop just lost its zoom-out"
    assert_equal CROP, card["image_crop"]
  end

  test "a crop without its source, and a source without its image, are dropped" do
    card = patch_cards([ { type: "multiple_choice", text: "Q", options: [ "A" ],
                           image: IMAGE, image_crop: CROP } ])
    assert_nil card["image_crop"], "a crop rect with no source describes nothing"

    card = patch_cards([ { type: "multiple_choice", text: "Q", options: [ "A" ],
                           image_source: SOURCE, image_crop: CROP } ])
    assert_nil card["image_source"], "a source with no image on the card is dead data"
    assert_nil card["image_crop"]
  end

  test "an off-allowlist source takes its crop down with it" do
    card = patch_cards([ { type: "multiple_choice", text: "Q", options: [ "A" ],
                           image: IMAGE, image_source: "https://evil.example/x.png",
                           image_crop: CROP } ])

    assert_nil card["image_source"],
               "image_source must pass the same allowlist as any image value"
    assert_nil card["image_crop"]
    assert_equal IMAGE, card["image"], "the visible image itself is untouched"
  end

  test "a populate/shuffle pick clears the previous upload's re-crop record" do
    # A shuffle puts a DIFFERENT picture on the card. A record left behind
    # would make "Adjust crop" reopen the previous photo underneath it.
    card = { "image" => IMAGE, "image_source" => SOURCE, "image_crop" => CROP.dup }
    AssetPopulator.new(@survey).apply_card_media(card, { "image" => "https://images.pexels.com/photos/1/a.jpeg" })

    assert_equal "https://images.pexels.com/photos/1/a.jpeg", card["image"]
    assert_nil card["image_source"]
    assert_nil card["image_crop"]
  end

  test "a junk rect is dropped while a good source is kept" do
    card = patch_cards([ { type: "multiple_choice", text: "Q", options: [ "A" ],
                           image: IMAGE, image_source: SOURCE,
                           image_crop: { "x" => "junk" } } ])

    assert_equal SOURCE, card["image_source"]
    assert_nil card["image_crop"]
  end
end
