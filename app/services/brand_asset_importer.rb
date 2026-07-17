require "net/http"
require "tempfile"
require "resolv"
require "ipaddr"

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
  MAX_REDIRECTS      = 5

  # SSRF guard: a remote source URL (or any redirect hop) must not resolve into
  # the cloud metadata endpoint, loopback, or private/link-local space.
  BLOCKED_IP_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15
    ::1/128 ::/128 fc00::/7 fe80::/10 ::ffff:0:0/96
  ].map { |r| IPAddr.new(r) }.freeze

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

  # Bytes read per candidate are capped at one over the per-file limit — enough
  # for import_one to reject an over-size file, but never more. This bounds
  # memory to ASSET_MAX_BYTES+1 per entry so a decompression bomb (a tiny zip
  # entry that inflates to gigabytes) or a huge local file is skipped, not
  # slurped into RAM and OOM-killing the instance.
  READ_CAP = Organisation::ASSET_MAX_BYTES + 1

  # Yields [filename, read_bytes_lambda] for every non-dotfile the source holds
  # (a directory, a zip, or a single file). Bytes are read lazily (and capped)
  # so a large non-image (a PDF or font in a brand kit) is reported and skipped
  # without being slurped into memory.
  def each_candidate(path, &block)
    if File.directory?(path)
      # Recurse: brand kits arrive foldered (Backgrounds/, Select Icons/, …).
      # The stored name is the basename; a dotfile anywhere in the path (e.g.
      # __MACOSX/._x, .DS_Store) is skipped.
      Dir.glob("**/*", base: path).sort.each do |rel|
        file = File.join(path, rel)
        next unless File.file?(file)
        next if rel.split("/").any? { |seg| seg.start_with?(".") }
        yield File.basename(rel), -> { File.binread(file, READ_CAP) }
      end
    elsif zip?(path)
      Zip::File.open(path) do |zip|
        zip.entries.sort_by(&:name).each do |entry|
          next unless entry.file?
          base = File.basename(entry.name)
          next if base.start_with?(".") # skip __MACOSX/ and dotfiles
          # Read (capped) within the open block — the caller consumes it now.
          yield base, -> { entry.get_input_stream.read(READ_CAP) }
        end
      end
    else
      yield File.basename(path), -> { File.binread(path, READ_CAP) }
    end
  end

  # Resolves the source to a local path — downloading first for an http(s) URL.
  # The tempfile keeps the URL's file extension so a single-image URL (not just
  # a zip) is recognised by each_candidate.
  def with_local_path(&block)
    if @source.match?(%r{\Ahttps?://}i)
      ext = File.extname(URI.parse(@source).path.to_s)[0, 12].to_s
      Tempfile.create([ "brand-assets", ext ]) do |tmp|
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

  # Streams a remote source to `io`, following redirects manually so every hop
  # is SSRF-checked (open-uri would follow them blind). Each hop's host is
  # resolved and rejected if it lands in loopback/private/link-local/metadata
  # space, and the socket is pinned to the validated IP so DNS can't rebind
  # between the check and the connect. The transfer is byte-capped.
  def download(url, io)
    written = 0
    MAX_REDIRECTS.times do
      uri = URI.parse(url)
      raise ArgumentError, "only http(s) sources are supported" unless uri.is_a?(URI::HTTP)

      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr      = validated_ip(uri.host) # pin socket to the checked IP
      http.use_ssl     = uri.is_a?(URI::HTTPS)
      http.open_timeout = 10
      http.read_timeout = 30

      redirect = nil
      http.start do
        http.request(Net::HTTP::Get.new(uri)) do |resp|
          case resp
          when Net::HTTPRedirection
            redirect = URI.join(url, resp["location"].to_s).to_s
          when Net::HTTPSuccess
            resp.read_body do |chunk|
              written += chunk.bytesize
              raise ArgumentError, "download exceeds #{MAX_DOWNLOAD_BYTES / (1024 * 1024)} MB" if written > MAX_DOWNLOAD_BYTES
              io.write(chunk)
            end
          else
            raise ArgumentError, "fetch failed (HTTP #{resp.code})"
          end
        end
      end

      return unless redirect # success — done
      url = redirect
    end
    raise ArgumentError, "too many redirects (> #{MAX_REDIRECTS})"
  end

  # The host's resolved address, or raise if ANY of its addresses is in blocked
  # (loopback/private/link-local/metadata) space. Returns the IP to connect to.
  def validated_ip(host)
    addrs = Resolv.getaddresses(host)
    raise ArgumentError, "could not resolve host: #{host}" if addrs.empty?
    addrs.each do |a|
      ip = IPAddr.new(a) rescue next
      if BLOCKED_IP_RANGES.any? { |r| r.include?(ip) }
        raise ArgumentError, "refusing to fetch a private/loopback/link-local host: #{host}"
      end
    end
    addrs.first
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
