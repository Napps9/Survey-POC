require "test_helper"

class OrganisationAssetsTest < ActionDispatch::IntegrationTest
  def setup
    @org    = Organisation.create!(name: "Econ", slug: "econ-#{SecureRandom.hex(2)}")
    @admin  = User.create!(name: "Adm", email_address: "adm-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @member = User.create!(name: "Mem", email_address: "mem-#{SecureRandom.hex(2)}@test.com", password: "verylongpassword")
    @org.memberships.create!(user: @admin,  role: "admin")
    @org.memberships.create!(user: @member, role: "member")
  end

  def login(user)
    post session_path, params: { email_address: user.email_address, password: "verylongpassword" }
    follow_redirect! if response.redirect?
  end

  def png_upload(name = "brand.png")
    Rack::Test::UploadedFile.new(StringIO.new("\x89PNG\r\n\x1a\n"), "image/png", original_filename: name)
  end

  def attach_asset(name = "hero.png")
    @org.assets.attach(io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: name, content_type: "image/png")
  end

  test "an admin uploads brand assets" do
    login(@admin)
    assert_difference -> { @org.reload.assets.attachments.size }, 2 do
      post organisation_assets_path(@org), params: { assets: [ png_upload("a.png"), png_upload("b.png") ] }
    end
    assert_redirected_to organisation_memberships_path(@org)
  end

  test "the multipart path enforces the library cap" do
    stub_max = Organisation::MAX_ASSETS
    Organisation.send(:remove_const, :MAX_ASSETS)
    Organisation.const_set(:MAX_ASSETS, 1)
    attach_asset
    login(@admin)
    assert_no_difference -> { @org.reload.assets.attachments.size } do
      post organisation_assets_path(@org), params: { assets: [ png_upload("a.png"), png_upload("b.png") ] }
    end
    assert_redirected_to organisation_memberships_path(@org)
    assert_match(/exceed your 1-asset limit/, flash[:alert])
  ensure
    Organisation.send(:remove_const, :MAX_ASSETS)
    Organisation.const_set(:MAX_ASSETS, stub_max)
  end

  # What makes an upload a valid asset here is its content type; what decides
  # whether the stored blob PATH survives Survey.sanitize_image_url is its
  # extension. An asset named "logo" or "holiday.jfif" used to be stored under
  # that name, pick fine in the editor, and then be dropped from the card on
  # save — "Saved, but an image didn't stick — check and re-upload it.", every
  # time, with re-uploading the same file reproducing it exactly.
  test "an upload with no usable extension is stored under a name a card can keep" do
    login(@admin)
    post organisation_assets_path(@org), params: { assets: [ png_upload("company-logo") ] }

    stored = @org.reload.assets.attachments.last.blob
    assert_equal "company-logo.png", stored.filename.to_s
    path = Rails.application.routes.url_helpers.rails_blob_path(stored, only_path: true)
    assert_equal path, Survey.sanitize_image_url(path), "the stored path must survive the card sanitiser"
  end

  test "an upload whose extension the sanitiser rejects gains one that works" do
    login(@admin)
    jfif = Rack::Test::UploadedFile.new(StringIO.new("\xFF\xD8\xFF"), "image/jpeg", original_filename: "holiday.jfif")
    post organisation_assets_path(@org), params: { assets: [ jfif ] }

    stored = @org.reload.assets.attachments.last.blob
    assert_equal "holiday.jfif.jpg", stored.filename.to_s, "the creator's own name stays recognisable"
    path = Rails.application.routes.url_helpers.rails_blob_path(stored, only_path: true)
    assert_equal path, Survey.sanitize_image_url(path)
  end

  test "an upload that already has a usable extension keeps its own filename" do
    login(@admin)
    post organisation_assets_path(@org), params: { assets: [ png_upload("Autumn Campaign.PNG") ] }

    assert_equal "Autumn Campaign.PNG", @org.reload.assets.attachments.last.blob.filename.to_s
  end

  test "an SVG upload is still scrubbed, and keeps its bytes" do
    login(@admin)
    svg = Rack::Test::UploadedFile.new(
      StringIO.new(%(<svg xmlns="http://www.w3.org/2000/svg"><rect width="4" height="4"/></svg>)),
      "image/svg+xml", original_filename: "mark"
    )
    post organisation_assets_path(@org), params: { assets: [ svg ] }

    stored = @org.reload.assets.attachments.last.blob
    assert_equal "mark.svg", stored.filename.to_s
    assert_match "<rect", stored.download, "the sanitised SVG body is what got stored"
  end

  test "the bytes of a renamed upload are the bytes that were uploaded" do
    login(@admin)
    post organisation_assets_path(@org), params: { assets: [ png_upload("no-extension") ] }

    assert_equal "\x89PNG\r\n\x1a\n".b, @org.reload.assets.attachments.last.blob.download.b
  end

  test "a non-admin cannot upload brand assets" do
    login(@member)
    assert_no_difference -> { @org.reload.assets.attachments.size } do
      post organisation_assets_path(@org), params: { assets: [ png_upload ] }
    end
    assert_redirected_to root_path
  end

  test "a non-image upload is rejected before it is stored" do
    login(@admin)
    bad = Rack::Test::UploadedFile.new(StringIO.new("nope"), "text/plain", original_filename: "x.txt")
    assert_no_difference -> { @org.reload.assets.attachments.size } do
      post organisation_assets_path(@org), params: { assets: [ bad ] }
    end
    assert_redirected_to organisation_memberships_path(@org)
    assert_match(/PNG|image/i, flash[:alert])
  end

  test "an admin removes a brand asset" do
    attach_asset("z.png")
    att = @org.reload.ordered_assets.first
    login(@admin)
    assert_difference -> { @org.reload.assets.attachments.size }, -1 do
      delete organisation_asset_path(@org, att.id)
    end
    assert_redirected_to organisation_memberships_path(@org)
  end

  test "the branding page lists the brand asset library" do
    attach_asset
    login(@admin)
    get organisation_memberships_path(@org)
    assert_response :success
    assert_match "Brand asset library", response.body
    assert_match "/rails/active_storage/", response.body
  end

  test "the editor media picker shows the org's brand library section" do
    attach_asset
    survey = @org.surveys.create!(title: "S", theme: "T", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [])
    login(@admin)
    get survey_path(survey)
    assert_response :success
    assert_match "Your brand library", response.body
    assert_match "media-library-item", response.body
    # Tile shows a resized VARIANT (thumbnail); picking applies the full blob.
    assert_match "/rails/active_storage/representations/", response.body
    assert_match %r{data-url="/rails/active_storage/blobs/}, response.body
  end

  # ── Editor → library (JSON data-URL path) ──────────────────────────────────
  # The media picker POSTs the same base64 payload shape as surveys#card_image,
  # so an editor upload can also land in the brand library.

  PNG_DATA_URL = "data:image/png;base64,#{Base64.strict_encode64("\x89PNG\r\n\x1a\n")}".freeze

  def json_create(image)
    post organisation_assets_path(@org, format: :json),
         params: { image: image }.to_json,
         headers: { "CONTENT_TYPE" => "application/json", "Accept" => "application/json" }
  end

  test "an admin saves an editor upload into the library via JSON" do
    login(@admin)
    assert_difference -> { @org.reload.assets.attachments.size }, 1 do
      json_create(PNG_DATA_URL)
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert body["ok"]
    assert_match %r{/rails/active_storage/blobs/}, body["url"]
    assert body["thumb"].present?
    assert body["id"].present?
  end

  test "the JSON path enforces the library cap" do
    stub_max = Organisation::MAX_ASSETS
    Organisation.send(:remove_const, :MAX_ASSETS)
    Organisation.const_set(:MAX_ASSETS, 1)
    attach_asset
    login(@admin)
    assert_no_difference -> { @org.reload.assets.attachments.size } do
      json_create(PNG_DATA_URL)
    end
    assert_response :unprocessable_entity
    refute JSON.parse(response.body)["ok"]
  ensure
    Organisation.send(:remove_const, :MAX_ASSETS)
    Organisation.const_set(:MAX_ASSETS, stub_max)
  end

  test "the JSON path rejects junk and disallowed content types" do
    login(@admin)
    assert_no_difference -> { @org.reload.assets.attachments.size } do
      json_create("not-a-data-url")
      assert_response :unprocessable_entity
      json_create("data:application/pdf;base64,#{Base64.strict_encode64("%PDF")}")
      assert_response :unprocessable_entity
    end
  end

  test "an SVG data URL is sanitised before it reaches the library" do
    login(@admin)
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><script>alert(1)</script><rect width="10" height="10"/></svg>)
    json_create("data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}")

    assert_response :success
    stored = @org.reload.assets.attachments.last.blob.download
    refute_match(/script/i, stored)
    assert_includes stored, "<rect"
  end

  test "a non-admin cannot use the JSON path" do
    login(@member)
    assert_no_difference -> { @org.reload.assets.attachments.size } do
      json_create(PNG_DATA_URL)
    end
    assert_response :forbidden
  end

  test "the media picker offers save-to-library and the add tile to admins only" do
    survey = @org.surveys.create!(title: "S", theme: "T", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [])
    login(@admin)
    get survey_path(survey)
    assert_response :success
    # Markup, not strings — the label text also ships in the window.I18N blob
    # on every page, so a string match can't tell UI from translations.
    assert_select "[data-media-picker-target=saveToLibrary]", 1
    assert_select ".media-library-add", 1

    login(@member)
    get survey_path(survey)
    assert_response :success
    assert_select "[data-media-picker-target=saveToLibrary]", 0
    assert_select ".media-library-add", 0
  end

  # ── Removing a brand asset from inside the picker ───────────────────────
  # The capability already existed on Settings → Brand; what was missing was
  # the affordance in the grid a creator is actually looking at when they
  # decide an image was a mistake.

  def json_destroy(id)
    delete organisation_asset_path(@org, id, format: :json),
           headers: { "Accept" => "application/json" }
  end

  test "an admin removes a brand asset over JSON without being redirected" do
    attach_asset("bye.png")
    att = @org.reload.ordered_assets.first
    login(@admin)

    assert_difference -> { @org.reload.assets.attachments.size }, -1 do
      json_destroy(att.id)
    end
    assert_response :success
    # A redirect is the wrong answer inside a modal: Turbo would follow it and
    # navigate the editor away, taking the creator's unsaved cards with it.
    assert_equal true, response.parsed_body["ok"]
    assert_equal att.id, response.parsed_body["id"]
  end

  test "a non-admin cannot remove a brand asset over JSON" do
    attach_asset("keep.png")
    att = @org.reload.ordered_assets.first
    login(@member)

    assert_no_difference -> { @org.reload.assets.attachments.size } do
      json_destroy(att.id)
    end
    assert_response :forbidden
    assert_equal false, response.parsed_body["ok"]
  end

  test "a JSON delete of an id this account does not own is a not-found, not a purge" do
    other = Organisation.create!(name: "Rival", slug: "rival-#{SecureRandom.hex(2)}")
    other.assets.attach(io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: "theirs.png",
                        content_type: "image/png")
    theirs = other.reload.ordered_assets.first
    login(@admin)

    assert_no_difference -> { other.reload.assets.attachments.size } do
      json_destroy(theirs.id)
    end
    assert_response :not_found
    assert_equal false, response.parsed_body["ok"]
  end

  test "the create JSON hands back a delete url so a fresh tile is removable" do
    login(@admin)
    json_create(PNG_DATA_URL)
    assert_response :success

    body = response.parsed_body
    # Without this the one tile you could NOT remove was the one you had just
    # uploaded — the picker had no id to delete it by until a full reload.
    assert body["delete_url"].present?, "create should return the tile's delete url"
    assert_difference -> { @org.reload.assets.attachments.size }, -1 do
      delete body["delete_url"], headers: { "Accept" => "application/json" }
    end
    assert_response :success
  end

  test "the picker's brand tiles carry a remove button for admins only" do
    attach_asset("shown.png")
    survey = @org.surveys.create!(title: "S", theme: "T", audience_age: "all", key_insight: "k",
                                  default_locale: "en", locales: [ "en" ], cards: [])

    login(@admin)
    get survey_path(survey)
    assert_response :success
    assert_select ".media-library-cell .media-library-del", 1
    # The tile needs its own identity for the JS to clear a pending pick that
    # points at a blob it has just purged.
    assert_select ".media-library-cell .media-library-item[data-asset-id]", 1

    login(@member)
    get survey_path(survey)
    assert_response :success
    assert_select ".media-library-del", 0
    # ...but a member still SEES the library. Gating the tile must not gate
    # the picture.
    assert_select ".media-library-cell .media-library-item", 1
  end
end
