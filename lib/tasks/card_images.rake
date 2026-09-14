namespace :card_images do
  desc "Move inline base64 card images into Active Storage (DRY_RUN=1 to preview)"
  task backfill: :environment do
    dry_run = ENV["DRY_RUN"].present?
    result  = Survey::CardImageBackfill.run(dry_run: dry_run, logger: ->(msg) { puts "  #{msg}" })

    puts ""
    puts "#{dry_run ? '[DRY RUN] ' : ''}images converted: #{result.converted}"
    puts "vertos with nothing to do: #{result.skipped}"
    puts "conversions failed (left as data-URLs): #{result.failed}" if result.failed.positive?
    puts "database bytes reclaimed: ~#{ActiveSupport::NumberHelper.number_to_human_size(result.freed_bytes)}"
  end

  # The images the backfill above cannot move: inline base64 too large for the
  # store. Shrunk to the browser's own upload size and stored, one card at a
  # time (see Survey::CardImageShrink for why that is the memory-safe shape).
  # Idempotent — a converted card is no longer a candidate — so a run that a
  # deploy cuts short is simply run again.
  #
  #   DRY_RUN=1 bin/rails card_images:shrink_oversized   # list them
  #   bin/rails card_images:shrink_oversized             # shrink and store them
  desc "Shrink inline card images too large for the store, and store them (DRY_RUN=1 to list)"
  task shrink_oversized: :environment do
    dry_run = ENV["DRY_RUN"].present?
    found   = Survey::CardImageShrink.candidates
    puts "#{found.size} inline card image(s) over the cap"

    found.each do |c|
      if dry_run
        puts "  [DRY RUN] Verto #{c.survey_id} card #{c.cid}: #{c.bytes} bytes"
        next
      end
      r = Survey::CardImageShrink.shrink!(c.survey_id, c.cid)
      puts "  Verto #{r.survey_id} card #{r.cid}: #{r.before_bytes} -> #{r.after_bytes} bytes " \
           "(#{r.width}x#{r.height}) #{r.path}"
    rescue => e
      warn "  ! Verto #{c.survey_id} card #{c.cid}: #{e.class}: #{e.message}"
    end
  end
end
