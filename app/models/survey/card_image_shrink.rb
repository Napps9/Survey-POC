# Inline card images the store refuses for SIZE: a raw camera JPEG stored as
# base64 in the `cards` column before uploads were downscaled in the browser.
# CardImageBackfill leaves them in place ("a fat image beats a broken one"),
# the sanitiser drops them on the deck's next editor save — with the status
# pill naming the card — and until then every editor and player render
# carries the whole thing. 2026-09-14: two of them, 12 and 10 MB decoded, on
# one card each of a published Verto and its copy, after the backfill had
# converted everything else.
#
# This does what the upload path would have done to the same file: MAX_EDGE
# pixels on the longest side, JPEG, stored as a blob through CardImageStore,
# the card's value swapped for the path. The picture survives; the deck loses
# the megabytes.
#
# Memory is the whole design. The deck holding a 16 MB image IS 16 MB of JSON,
# and where this runs is the 512 MB production web container, beside the
# process serving traffic (docs/DEPLOYMENT_RUNBOOK.md §2). So the deck is read
# once with `pick`, not as a Survey row; the deck's own reference to the
# base64 is dropped before the decoded bytes are held; and the write is an
# update_all — which also keeps every save callback off a published deck, the
# same posture CardImageBackfill takes with update_columns.
class Survey
  module CardImageShrink
    MAX_EDGE = 1600 # media_picker_controller.js MAX_EDGE — the browser's own downscale
    QUALITY  = 82   # …and its ENCODE_QUALITY

    Candidate = Struct.new(:survey_id, :cid, :bytes, keyword_init: true)
    Result    = Struct.new(:survey_id, :cid, :before_bytes, :after_bytes, :width, :height, :path,
                           keyword_init: true)

    # Every card whose `image` is still inline AND over the sanitiser's cap —
    # exactly the set the backfill could not move and the next editor save
    # will drop. Small batches: a batch is held whole, and one deck can be
    # 16 MB.
    def self.candidates
      Survey.where.not(cards: nil).find_each(batch_size: 20).flat_map do |survey|
        Array(survey.cards).filter_map do |card|
          next unless card.is_a?(Hash) && oversized?(card["image"])
          Candidate.new(survey_id: survey.id, cid: card["cid"].to_s, bytes: card["image"].bytesize)
        end
      end
    end

    def self.oversized?(value)
      CardImageStore.data_url?(value) && value.to_s.bytesize > MAX_BACKGROUND_DATA_URL_BYTES
    end

    # Shrinks one card's inline image and stores it. Returns a Result; raises
    # when the card is missing or its image is not inline — nothing is written
    # in either case.
    #
    # `resize:` turns raw image bytes into [jpeg_bytes, width, height]. The
    # default is libvips, which the production image ships (Dockerfile) and a
    # test runner may not — the seam is what lets everything around the resize
    # be tested without it.
    def self.shrink!(survey_id, cid, resize: method(:resize_with_vips))
      cards = Survey.where(id: survey_id).pick(:cards)
      card  = Array(cards).find { |c| c.is_a?(Hash) && c["cid"].to_s == cid.to_s }
      raise ArgumentError, "Verto #{survey_id} has no card #{cid}" unless card
      value = card["image"].to_s
      raise ArgumentError, "Verto #{survey_id} card #{cid} is not an inline image" unless CardImageStore.data_url?(value)

      before = value.bytesize
      bytes  = Base64.decode64(value[(value.index(",") + 1)..])
      # The deck's own reference to the base64 goes now, not when this method
      # returns: from here the process holds the decoded bytes, not both.
      card["image"] = nil
      value = nil
      GC.start

      jpeg, width, height = resize.call(bytes)
      bytes = nil

      survey = Survey.find(survey_id)
      blob   = CardImageStore.attach(survey, "data:image/jpeg;base64,#{Base64.strict_encode64(jpeg)}")
      raise "the store refused the shrunk image (#{jpeg.bytesize} bytes)" unless blob

      card["image"] = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
      # updated_at as well: the play page is cached under it (PlayerController),
      # so a published Verto's respondents get the lighter page on their next
      # visit rather than when the cache expires.
      Survey.where(id: survey_id).update_all(cards: cards, updated_at: Time.current)

      Result.new(survey_id: survey_id, cid: cid.to_s, before_bytes: before, after_bytes: jpeg.bytesize,
                 width: width, height: height, path: card["image"])
    end

    # libvips thumbnails a JPEG at reduced scale on load, so a 20-megapixel
    # original is never decoded whole. `size: :down` never enlarges a small
    # one. Required here, not at boot: the Gemfile loads ruby-vips lazily.
    def self.resize_with_vips(bytes)
      require "vips"
      image = Vips::Image.thumbnail_buffer(bytes, MAX_EDGE, height: MAX_EDGE, size: :down)
      [ image.write_to_buffer(".jpg", Q: QUALITY), image.width, image.height ]
    end
  end
end
