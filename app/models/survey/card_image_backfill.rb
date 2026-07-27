# One-off conversion of decks authored before card imagery moved to Active
# Storage: rewrites inline base64 data-URLs in `cards` (and `background_image`)
# into stored blobs, leaving a short path behind.
#
# Until a Verto is converted it still works — sanitize_image_url continues to
# accept data-URLs — it just keeps carrying its images in the database column,
# which is the memory driver behind the production 502s (P1-7).
#
# Idempotent: anything already holding a path is skipped, so a partial run can
# simply be re-run.
class Survey
  class CardImageBackfill
    Result = Struct.new(:converted, :failed, :skipped, :freed_bytes, keyword_init: true)

    def self.run(dry_run: false, logger: nil)
      new(dry_run: dry_run, logger: logger).run
    end

    def initialize(dry_run: false, logger: nil)
      @dry_run = dry_run
      @logger  = logger
      @result  = Result.new(converted: 0, failed: 0, skipped: 0, freed_bytes: 0)
    end

    def run
      Survey.where.not(cards: nil).find_each(batch_size: 50) { |survey| process(survey) }
      @result
    end

    private

    def process(survey)
      # Work on a deep copy so a failure part-way through leaves the stored deck
      # untouched rather than half-rewritten.
      cards      = JSON.parse(Array(survey.cards).to_json)
      background = survey.read_attribute(:background_image)
      touched    = false

      cards.each do |card|
        next unless card.is_a?(Hash)

        if (url = convert(survey, card["image"]))
          card["image"] = url
          touched = true
        end

        Array(card["option_images"]).each_with_index do |option_image, i|
          if (url = convert(survey, option_image))
            card["option_images"][i] = url
            touched = true
          end
        end
      end

      if (url = convert(survey, background))
        background = url
        touched = true
      end

      unless touched
        @result.skipped += 1
        return
      end
      return if @dry_run

      # update_columns skips validations, callbacks and the range-scale
      # normalisation that runs on save. This task only rewrites image URLs and
      # must not be able to reshape a deck as a side effect — least of all a
      # published Verto, whose stored answers are indexes into its options.
      survey.update_columns(cards: cards, background_image: background)
      log "converted Verto #{survey.id} (#{survey.title})"
    end

    # The stored path for a converted image, or nil when there was nothing to do
    # (already a path, blank) or the conversion failed — in which case the caller
    # leaves the data-URL in place. A fat image beats a broken one.
    def convert(survey, value)
      return nil unless CardImageStore.data_url?(value)

      size = value.to_s.bytesize
      if @dry_run
        return nil unless CardImageStore.decode(value)

        tally(size)
        return "(dry-run)"
      end

      blob = CardImageStore.attach(survey, value)
      unless blob
        @result.failed += 1
        return nil
      end

      tally(size)
      Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
    rescue => e
      @result.failed += 1
      log "! Verto #{survey.id}: #{e.class} #{e.message}"
      nil
    end

    def tally(size)
      @result.converted   += 1
      @result.freed_bytes += size
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
