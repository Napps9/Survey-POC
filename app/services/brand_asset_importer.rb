require "open-uri"
require "tempfile"

# Bulk-loads images into an organisation's brand asset library (Organisation
# #assets). Built for the ops task of seeding a customer account's brand kit
# without click-uploading each file — e.g. `brand_assets:import`. The source can
# be a local directory, a local .zip, a single image file, or an http(s) URL to
# any of those (the URL is fetched server-side, so run it where the target's
# Active Storage lives — the prod container, whose disk it writes to).
#
# Every image is validated the same way the editor upload is (supported type,
# per-file size cap, MAX_ASSETS ceiling) and de-duplicated by filename, so the
# task is safe to re-run.
class BrandAssetImporter
  Result = Struct.new(:added, :skipped, :errors, keyword_init: true) do
    def summary
      "added #{added.size}, skipped #{skipped.size}, error(s) #{errors.size}"
    end
  end

  EXT_TYPES = {
    ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
    ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml"
  }.freeze
  MAX_DOWNLOAD_BYTES = 200 * 1024 * 1024 # backstop for a remote fetch

  def self.call(...)
    new(...).call
  end

  def initialize(org:, source:)
    @org    = org
    @source = source.to_s
  end

  def call
    result  = Result.new(added: [], skipped: [], errors: [])
    @seen   = @org.assets.attachments.map { |a| a.blob.filename.to_s }.to_set
    @count  = @seen.size
    with_local_path do |path|
      each_candidate(path) do |filename, read_bytes|
        ct = EXT_TYPES[File.extname(filename).downcase]
        if ct.nil?
          result.skipped << [ filename, "not an image" ]
        else
          import_one(filename, read_bytes.call, ct, result)
        end
      end
    end
    result
  end

  private

  # Yields [filename, read_bytes_lambda] for every non-dotfile the source holds
  # (a directory, a zip, or a single file). Bytes are read lazily so a large
  # non-image (a PDF or font in a brand kit) is reported and skipped without
  # being slurped into memory.
  def each_candidate(path, &block)
    if File.directory?(path)
      # Recurse: brand kits arrive foldered (Backgrounds/, Select Icons/, …).
      # The stored name is the basename; a dotfile anywhere in the path (e.g.
      # __MACOSX/._x, .DS_Store) is skipped.
      Dir.glob("**/*", base: path).sort.each do |rel|
        file = File.join(path, rel)
        next unless File.file?(file)
        next if rel.split("/").any? { |seg| seg.start_with?(".") }
        yield File.basename(rel), -> { File.binread(file) }
      end
    elsif zip?(path)
      Zip::File.open(path) do |zip|
        zip.entries.sort_by(&:name).each do |entry|
          next unless entry.file?
          base = File.basename(entry.name)
          next if base.start_with?(".") # skip __MACOSX/ and dotfiles
          # Read within the open block (the caller consumes it synchronously).
          yield base, -> { entry.get_input_stream.read }
        end
      end
    else
      yield File.basename(path), -> { File.binread(path) }
    end
  end

  # Resolves the source to a local path — downloading first for an http(s) URL.
  def with_local_path(&block)
    if @source.match?(%r{\Ahttps?://}i)
      Tempfile.create([ "brand-assets", "" ]) do |tmp|
        tmp.binmode
        download(@source, tmp)
        tmp.flush
        block.call(tmp.path)
      end
    else
      raise ArgumentError, "source not found: #{@source}" unless File.exist?(@source)
      block.call(@source)
    end
  end

  def download(url, io)
    uri = URI.parse(url)
    raise ArgumentError, "only http(s) sources are supported" unless uri.is_a?(URI::HTTP)
    written = 0
    uri.open("rb") do |remote| # open-uri handles redirects (e.g. Drive's download redirect)
      while (chunk = remote.read(64 * 1024))
        written += chunk.bytesize
        raise ArgumentError, "download exceeds #{MAX_DOWNLOAD_BYTES / (1024 * 1024)} MB" if written > MAX_DOWNLOAD_BYTES
        io.write(chunk)
      end
    end
  end

  def zip?(path)
    File.binread(path, 4) == "PK\x03\x04".b
  end

  def import_one(filename, bytes, content_type, result)
    return result.skipped << [ filename, "library full (max #{Organisation::MAX_ASSETS})" ] if @count >= Organisation::MAX_ASSETS
    return result.skipped << [ filename, "already present" ] if @seen.include?(filename)
    return result.skipped << [ filename, "too large (> #{Organisation::ASSET_MAX_BYTES / (1024 * 1024)} MB)" ] if bytes.bytesize > Organisation::ASSET_MAX_BYTES
    return result.skipped << [ filename, "unsupported type #{content_type}" ] unless Organisation::ASSET_CONTENT_TYPES.include?(content_type)

    @org.assets.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
    @seen << filename
    @count += 1
    result.added << filename
  rescue => e
    result.errors << [ filename, e.message ]
  end
end
