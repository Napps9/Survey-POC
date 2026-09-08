module ObjectStorage
  # Moves Active Storage blobs between two services declared in
  # config/storage.yml — production's `local` disk → the shared `bucket` — with
  # the app still running. Per blob: copy the bytes (checksum-verified on the
  # read AND the write), then flip `active_storage_blobs.service_name`, so a
  # blob is served from the disk right up to the instant its copy is complete
  # and from the bucket immediately after. Nothing is ever deleted from the
  # source, which is what makes `rollback!` a pure metadata flip.
  #
  # Idempotent and resumable: a blob whose bytes already reached the
  # destination is only flipped; a blob already flipped is out of scope; a blob
  # whose bytes are missing from the source is reported and left alone (it was
  # already unreadable — a 404 today is a 404 after). Run it again after the
  # app has been switched to the bucket to sweep up uploads that landed on the
  # disk in between. Variants are blobs too, so they come along unasked.
  #
  # Must run where the SOURCE is readable: for the Render disk that means a
  # shell on the web service itself (one-off jobs don't mount the disk).
  class Migrator
    Result = Struct.new(:total, :copied, :flipped, :skipped, :missing, :failed, keyword_init: true) do
      def to_s
        "total=#{total} copied=#{copied} flipped=#{flipped} skipped=#{skipped} missing=#{missing} failed=#{failed}"
      end

      def ok?
        failed.zero? && missing.zero?
      end
    end

    attr_reader :from, :to

    def initialize(from:, to:, dry_run: false, batch_size: 200, io: $stdout)
      @from = from.to_sym
      @to   = to.to_sym
      raise ArgumentError, "from and to must be different services" if @from == @to

      @dry_run    = dry_run
      @batch_size = batch_size
      @io         = io
    end

    def source
      @source ||= ActiveStorage::Blob.services.fetch(from)
    end

    def destination
      @destination ||= ActiveStorage::Blob.services.fetch(to)
    end

    # Counts per service — the before/after picture.
    def self.status
      ActiveStorage::Blob.group(:service_name).count
    end

    # Copy every blob still on `from` into `to`, flipping each as it lands.
    def run!
      scope  = ActiveStorage::Blob.where(service_name: from.to_s)
      result = fresh_result(scope.count)
      log "#{prefix}#{from} → #{to}: #{result.total} blob(s) to move"

      scope.find_each(batch_size: @batch_size) do |blob|
        begin
          if destination.exist?(blob.key)
            flip!(blob, to)
            result.flipped += 1
          elsif !source.exist?(blob.key)
            result.missing += 1
            log "  MISSING in #{from} (already unreadable, left alone): blob #{blob.id} #{blob.key} #{blob.filename}"
          else
            copy!(blob) unless dry_run?
            flip!(blob, to)
            result.copied += 1
          end
        rescue => e
          result.failed += 1
          log "  FAILED blob #{blob.id} #{blob.key}: #{e.class}: #{e.message}"
        end
        progress(result)
      end

      log "done: #{result}"
      result
    end

    # Point every blob on `to` back at `from`, where `from` still has the bytes.
    # A blob that exists ONLY in `to` (uploaded after the switch) is left there.
    def rollback!
      scope  = ActiveStorage::Blob.where(service_name: to.to_s)
      result = fresh_result(scope.count)
      log "#{prefix}rollback #{to} → #{from}: #{result.total} blob(s)"

      scope.find_each(batch_size: @batch_size) do |blob|
        begin
          if source.exist?(blob.key)
            flip!(blob, from)
            result.flipped += 1
          else
            result.skipped += 1
            log "  only in #{to} (uploaded after the switch?) — left as is: blob #{blob.id} #{blob.key}"
          end
        rescue => e
          result.failed += 1
          log "  FAILED blob #{blob.id} #{blob.key}: #{e.class}: #{e.message}"
        end
      end

      log "done: #{result}"
      result
    end

    # After a run: nothing left on `from`, and a random sample of the blobs now
    # on `to` really exists there.
    def verify(sample: 50)
      left    = ActiveStorage::Blob.where(service_name: from.to_s).count
      on_to   = ActiveStorage::Blob.where(service_name: to.to_s)
      # RANDOM() exists on both SQLite and Postgres (CLAUDE.md gotcha).
      picked  = on_to.order(Arel.sql("RANDOM()")).limit(sample).to_a
      present = picked.count { |blob| destination.exist?(blob.key) }
      log "verify: #{left} blob(s) still on #{from}; #{present}/#{picked.size} sampled #{to} blob(s) present"
      left.zero? && present == picked.size
    end

    private

    def dry_run?
      @dry_run
    end

    def prefix
      dry_run? ? "DRY RUN — " : ""
    end

    def fresh_result(total)
      Result.new(total: total, copied: 0, flipped: 0, skipped: 0, missing: 0, failed: 0)
    end

    # `open` streams to a tempfile and verifies the stored checksum on the way
    # in; `upload` verifies it again on the way out (Disk compares, S3 sends it
    # as Content-MD5) — a corrupt copy raises here instead of being flipped to.
    def copy!(blob)
      source.open(blob.key, checksum: blob.checksum) do |file|
        destination.upload(blob.key, file,
                           checksum:     blob.checksum,
                           content_type: blob.content_type,
                           filename:     blob.filename,
                           disposition:  :inline)
      end
    end

    def flip!(blob, service)
      return if dry_run? || blob.service_name == service.to_s

      blob.update_columns(service_name: service.to_s)
    end

    def progress(result)
      done = result.copied + result.flipped + result.skipped + result.missing + result.failed
      log "  #{done}/#{result.total}" if (done % 100).zero?
    end

    def log(message)
      @io.puts(message)
    end
  end
end
