require "test_helper"

class OrganisationTest < ActiveSupport::TestCase
  def build_org
    Organisation.new(name: "Logo Co", slug: "logo-#{SecureRandom.hex(3)}")
  end

  test "accepts a small PNG logo" do
    org = build_org
    org.logo.attach(io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: "logo.png", content_type: "image/png")
    assert org.valid?, org.errors.full_messages.to_sentence
  end

  test "rejects a non-image logo" do
    org = build_org
    org.logo.attach(io: StringIO.new("not an image"), filename: "evil.txt", content_type: "text/plain")
    refute org.valid?
    assert_match(/image/i, org.errors.full_messages.to_sentence)
  end

  test "rejects an oversized logo" do
    org = build_org
    org.logo.attach(io: StringIO.new("a" * (Organisation::LOGO_MAX_BYTES + 1)),
                    filename: "huge.png", content_type: "image/png")
    refute org.valid?
    assert_match(/2 MB|smaller/i, org.errors.full_messages.to_sentence)
  end

  # ── Brand asset library (has_many_attached :assets) ──

  def png_asset(org, name = "brand.png")
    org.assets.attach(io: StringIO.new("\x89PNG\r\n\x1a\n"), filename: name, content_type: "image/png")
  end

  test "accepts brand-library image assets" do
    org = build_org
    png_asset(org, "logo.png")
    png_asset(org, "hero.jpg")
    assert org.valid?, org.errors.full_messages.to_sentence
  end

  test "rejects a non-image brand asset" do
    org = build_org
    org.assets.attach(io: StringIO.new("nope"), filename: "evil.txt", content_type: "text/plain")
    refute org.valid?
    assert_match(/PNG|image/i, org.errors.full_messages.to_sentence)
  end

  test "rejects an oversized brand asset" do
    org = build_org
    org.assets.attach(io: StringIO.new("a" * (Organisation::ASSET_MAX_BYTES + 1)),
                      filename: "huge.png", content_type: "image/png")
    refute org.valid?
    assert_match(/MB|smaller/i, org.errors.full_messages.to_sentence)
  end

  test "rejects going over the asset count limit" do
    org = build_org
    (Organisation::MAX_ASSETS + 1).times { |i| png_asset(org, "a#{i}.png") }
    refute org.valid?
    assert_match(/full|max/i, org.errors.full_messages.to_sentence)
  end

  test "ordered_assets returns attachments newest first" do
    org = Organisation.create!(name: "Ord Co", slug: "ord-#{SecureRandom.hex(3)}")
    png_asset(org, "first.png"); org.save!
    png_asset(org, "second.png"); org.save!
    names = org.reload.ordered_assets.map { |a| a.blob.filename.to_s }
    assert_equal 2, names.size
    assert_includes names, "first.png"
    assert_includes names, "second.png"
  end
end
