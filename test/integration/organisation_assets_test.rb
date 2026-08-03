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
end
