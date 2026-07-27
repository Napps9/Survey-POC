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
end
