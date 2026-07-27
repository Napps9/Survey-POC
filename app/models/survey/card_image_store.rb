# Turns a base64 image data-URL into an Active Storage blob attached to a Verto.
#
# Card imagery used to be stored inline in the `cards` JSON as data-URLs. A deck
# with a handful of photos carried several MB of base64 in a single column, and
# every render — editor, preview, player, dashboard — re-materialized all of it
# into memory. On the 512MB instance that was the acknowledged driver behind the
# production 502s (PRODUCTION_READINESS_PLAN P1-7). Storing the bytes once and
# keeping a short path on the card removes that entirely.
#
# Used by both the live upload path (SurveysController#card_image) and the
# backfill of already-stored decks (lib/tasks/card_images.rake), so the decode,
# validation and naming rules can't drift between them.
class Survey
  module CardImageStore
    DATA_URL = %r{\Adata:(image/[a-zA-Z0-9.+-]+);base64,(.+)\z}m

    EXTENSIONS = {
      "image/png"  => "png",
      "image/jpeg" => "jpg",
      "image/gif"  => "gif",
      "image/webp" => "webp"
    }.freeze

    # Returns the attached blob, or nil if the value isn't a usable image.
    # Deliberately forgiving about *why* it failed — every caller's fallback is
    # the same (keep the data-URL), and the reason isn't actionable to a creator.
    def self.attach(survey, data_url)
      decoded = decode(data_url)
      return nil unless decoded

      bytes, content_type = decoded
      blob = ActiveStorage::Blob.create_and_upload!(
        io:           StringIO.new(bytes),
        # The filename's extension matters: Survey::ACTIVE_STORAGE_IMAGE_URL only
        # accepts a blob path ending in a real image extension, so a name without
        # one would be sanitized straight back out of the card.
        filename:     "card-#{SecureRandom.hex(8)}.#{EXTENSIONS.fetch(content_type)}",
        content_type: content_type
      )
      survey.card_images.attach(blob)
      blob
    end

    # [raw_bytes, content_type] for a valid, in-budget image data-URL; nil for
    # anything else (a path, a remote URL, junk, an unsupported format, or an
    # image over the size cap).
    def self.decode(value)
      match = DATA_URL.match(value.to_s.strip)
      return nil unless match

      content_type = match[1].downcase
      return nil unless Survey::CARD_IMAGE_CONTENT_TYPES.include?(content_type)

      bytes = begin
        Base64.strict_decode64(match[2].gsub(/\s+/, ""))
      rescue ArgumentError
        return nil
      end
      return nil if bytes.empty? || bytes.bytesize > Survey::CARD_IMAGE_MAX_BYTES

      [ bytes, content_type ]
    end

    # Whether a stored card value is still inline base64 (i.e. wants converting).
    def self.data_url?(value)
      value.to_s.strip.start_with?("data:image/")
    end
  end
end
