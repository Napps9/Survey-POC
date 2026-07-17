require "test_helper"
require "zip"

class BrandAssetImporterTest < ActiveSupport::TestCase
  PNG = "\x89PNG\r\n\x1a\n".b

  def setup
    @org = Organisation.create!(name: "Econ", slug: "econ-#{SecureRandom.hex(3)}")
  end

  def make_zip(entries)
    path = File.join(Dir.mktmpdir, "kit.zip")
    Zip::File.open(path, create: true) do |zip|
      entries.each { |name, bytes| zip.get_output_stream(name) { |o| o.write(bytes) } }
    end
    path
  end

  def filenames
    @org.reload.assets.attachments.map { |a| a.blob.filename.to_s }.sort
  end

  test "imports only the images from a zip, skipping other files" do
    zip = make_zip("logo.png" => PNG, "hero.jpg" => PNG, "guidelines.txt" => "text",
                   "__MACOSX/._logo.png" => "junk")
    result = BrandAssetImporter.call(org: @org, source: zip)

    assert_equal 2, result.added.size
    assert_equal %w[hero.jpg logo.png], filenames
    assert(result.skipped.any? { |fn, _| fn == "guidelines.txt" })
  end

  test "is idempotent — a second run adds nothing already present" do
    zip = make_zip("logo.png" => PNG, "hero.jpg" => PNG)
    BrandAssetImporter.call(org: @org, source: zip)
    result = BrandAssetImporter.call(org: @org, source: zip)

    assert_equal 0, result.added.size
    assert_equal 2, result.skipped.size
    assert_equal 2, @org.reload.assets.attachments.size
  end

  test "imports images from a directory" do
    dir = Dir.mktmpdir
    File.binwrite(File.join(dir, "a.png"), PNG)
    File.binwrite(File.join(dir, "b.webp"), PNG)
    File.write(File.join(dir, "notes.md"), "skip me")

    result = BrandAssetImporter.call(org: @org, source: dir)

    assert_equal 2, result.added.size
    assert_equal %w[a.png b.webp], filenames
  end

  test "recurses into subfolders (foldered brand kit)" do
    dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(dir, "Backgrounds"))
    FileUtils.mkdir_p(File.join(dir, "Select Icons"))
    FileUtils.mkdir_p(File.join(dir, "__MACOSX"))
    File.binwrite(File.join(dir, "Backgrounds", "bg-1.jpg"), PNG)
    File.binwrite(File.join(dir, "Select Icons", "icon-1.png"), PNG)
    File.binwrite(File.join(dir, "__MACOSX", "._bg-1.jpg"), "junk")

    result = BrandAssetImporter.call(org: @org, source: dir)

    assert_equal 2, result.added.size
    assert_equal %w[bg-1.jpg icon-1.png], filenames
  end

  test "imports a single image file" do
    dir = Dir.mktmpdir
    path = File.join(dir, "single.svg")
    File.binwrite(path, "<svg/>")
    result = BrandAssetImporter.call(org: @org, source: path)

    assert_equal 1, result.added.size
    assert_equal %w[single.svg], filenames
  end

  test "skips an oversized image" do
    big = "a".b * (Organisation::ASSET_MAX_BYTES + 1)
    zip = make_zip("ok.png" => PNG, "huge.png" => big)
    result = BrandAssetImporter.call(org: @org, source: zip)

    assert_equal %w[ok.png], filenames
    assert(result.skipped.any? { |fn, why| fn == "huge.png" && why.include?("too large") })
  end

  test "raises a clear error for a missing local source" do
    assert_raises(ArgumentError) { BrandAssetImporter.call(org: @org, source: "/no/such/path.zip") }
  end

  test "refuses a private/loopback/metadata URL (SSRF guard)" do
    %w[
      http://127.0.0.1/kit.zip
      http://localhost/kit.zip
      http://169.254.169.254/latest/meta-data
      http://10.0.0.5/kit.zip
      http://192.168.1.1/kit.zip
    ].each do |url|
      err = assert_raises(ArgumentError, "expected #{url} to be refused") do
        BrandAssetImporter.call(org: @org, source: url)
      end
      assert_match(/private|loopback|link-local|resolve/i, err.message)
    end
  end
end
