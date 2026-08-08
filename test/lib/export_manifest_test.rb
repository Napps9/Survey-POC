require "test_helper"
require "zlib"
require "tempfile"

# The claim that a citation traces to a known file.
#
# Ask Verto's whole promise is that a figure came from the question, the people
# and the study it says it did. The exports behind those figures are committed,
# so the one thing that could quietly break the chain is an export being edited
# after the fact: the import would succeed, every number would move, and nothing
# would say why. The manifest is what makes that loud.
class ExportManifestTest < ActiveSupport::TestCase
  def setup = ExportManifest.reset!

  test "every committed export is in the manifest, with the right shape" do
    files = Dir[ExportManifest::DIR.join("*.csv.gz")].map { |p| File.basename(p) }

    assert_operator files.size, :>, 0, "there should be committed exports to check"
    assert_equal files.sort, ExportManifest.entries.keys.sort,
      "an export with no entry cannot be imported, and an entry with no file is a dead record"
  end

  test "every entry names where it came from" do
    ExportManifest.entries.each do |name, entry|
      assert entry["source"].present?, "#{name} does not say which workbook it came from"
      assert_not_equal "UNKNOWN", entry["source"], "#{name} still has a placeholder source"
      assert entry["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/), "#{name} has no usable digest"
    end
  end

  # The expensive one — it decompresses every export — so it runs only when
  # asked. `VERIFY_EXPORTS=1 bin/rails test test/lib/export_manifest_test.rb`
  test "the committed exports still match their digests" do
    skip "set VERIFY_EXPORTS=1 to hash 200MB of exports" unless ENV["VERIFY_EXPORTS"]

    ExportManifest.entries.each_key do |name|
      assert_nothing_raised { ExportManifest.verify!(ExportManifest::DIR.join(name)) }
    end
  end

  test "a file that does not match its entry is refused, not imported" do
    Tempfile.create([ "fake", ".csv.gz" ], ExportManifest::DIR) do |file|
      Zlib::GzipWriter.wrap(file.tap(&:binmode)) { |gz| gz.write("Viewing ID,Language\nabc,en\n") }
      ExportManifest.instance_variable_set(:@entries,
        ExportManifest.entries.merge(File.basename(file.path) => { "sha256" => "0" * 64 }))

      error = assert_raises(ExportManifest::Mismatch) { ExportManifest.verify!(file.path) }
      assert_match(/does not match its manifest entry/, error.message)
      assert_match(/Refusing to import/, error.message)
    end
  ensure
    ExportManifest.reset!
  end

  test "a file the manifest does not claim is imported without a check" do
    # Test fixtures and one-off files are ordinary imports. Demanding an entry
    # for each would turn the manifest into paperwork rather than a record.
    fixture = Rails.root.join("test/fixtures/files/verto_import_sample.csv")

    assert_not ExportManifest.claims?(fixture)
    assert_nothing_raised { ExportManifest.verify!(fixture) }
  end

  test "the digest is of the decompressed bytes, not the archive" do
    # Otherwise re-gzipping at a different compression level would read as a
    # different dataset, and the check would cry wolf on every re-pack.
    body = "Viewing ID,Language\nabc,en\n"
    digests = [ 1, 9 ].map do |level|
      Tempfile.create([ "level#{level}", ".csv.gz" ]) do |file|
        Zlib::GzipWriter.wrap(file.tap(&:binmode), level) { |gz| gz.write(body) }
        ExportManifest.digest(file.path)
      end
    end

    assert_equal digests.first, digests.last
    assert_equal Digest::SHA256.hexdigest(body), digests.first
  end

  test "an export reads the same gzipped as it does plain" do
    plain = Rails.root.join("test/fixtures/files/verto_import_sample.csv")

    Tempfile.create([ "same", ".csv.gz" ]) do |file|
      Zlib::GzipWriter.wrap(file.tap(&:binmode)) { |gz| gz.write(File.read(plain)) }

      from_plain = VertoCsvImporter.new(csv_path: plain, admin_password: "a-long-enough-passphrase")
      from_gzip  = VertoCsvImporter.new(csv_path: file.path, admin_password: "a-long-enough-passphrase")

      assert_equal from_plain.each_row.to_a.map(&:fields), from_gzip.each_row.to_a.map(&:fields)
      assert_equal from_plain.headers, from_gzip.headers
    end
  end
end
