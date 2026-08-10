require "digest"
require "zlib"

# What each committed export IS, and proof that it still is.
#
# The exports in db/seeds/exports are the evidence behind every figure Ask Verto
# publishes. A citation that says "3,412 of 5,001 respondents" is only as good as
# the claim that the file it came from is the file the partner handed over — so
# the manifest records, per export, where it came from, what was done to it on
# the way in, and the SHA-256 of its decompressed bytes.
#
# The importer checks that digest before it reads a row. A file that does not
# match its entry is refused rather than imported, because a silently edited
# export is exactly the thing nobody would notice: the import would succeed, the
# numbers would move, and nothing would say why.
#
# A file OUTSIDE this directory is not claimed by the manifest and is imported
# without a check — test fixtures and one-off files are ordinary imports, and
# demanding an entry for each would turn the manifest into paperwork rather than
# a record.
module ExportManifest
  module_function

  DIR  = Rails.root.join("db/seeds/exports")
  FILE = DIR.join("manifest.yml")

  class Mismatch < StandardError; end

  def entries
    return {} unless File.exist?(FILE)

    @entries ||= YAML.safe_load_file(FILE) || {}
  end

  def reset! = @entries = nil

  def entry_for(path)
    entries[File.basename(path.to_s)]
  end

  # True when this path is one the manifest is responsible for.
  def claims?(path)
    File.expand_path(File.dirname(path.to_s)) == DIR.to_s
  end

  def verify!(path)
    return unless claims?(path)

    entry = entry_for(path)
    raise Mismatch, "#{File.basename(path)} is in db/seeds/exports but not in manifest.yml. " \
                    "Add it (bin/rails verto:manifest) so an import can be traced to a known file." if entry.nil?

    actual = digest(path)
    return if actual == entry["sha256"]

    raise Mismatch, "#{File.basename(path)} does not match its manifest entry.\n" \
                    "  expected sha256 #{entry['sha256']}\n" \
                    "  actual   sha256 #{actual}\n" \
                    "Refusing to import: a citation has to trace to a file whose contents are known."
  end

  # SHA-256 of the DECOMPRESSED bytes, so re-gzipping a file at a different
  # compression level does not read as a different dataset. Streamed — the
  # largest of these is 127 MB uncompressed.
  def digest(path)
    sha = Digest::SHA256.new
    each_chunk(path) { |chunk| sha.update(chunk) }
    sha.hexdigest
  end

  # Rows and columns, counted the same way the importer will read them, so an
  # entry can be checked by eye against the import's own summary.
  def shape(path)
    rows = 0
    columns = 0
    io = reader(path)
    CSV.new(io).each do |fields|
      columns = fields.size if rows.zero?
      rows += 1
    end
    { "rows" => [ rows - 1, 0 ].max, "columns" => columns }
  ensure
    io&.close
  end

  def reader(path)
    if path.to_s.end_with?(".gz")
      Zlib::GzipReader.new(File.open(path, "rb"), external_encoding: "UTF-8")
    else
      File.open(path, "r:bom|utf-8")
    end
  end

  def each_chunk(path)
    io = reader(path)
    while (chunk = io.read(1 << 20))
      yield chunk
    end
  ensure
    io&.close
  end
end
