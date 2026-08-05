namespace :option_label_emoji do
  desc "Move option-label emoji into their icon tiles on existing drafts (DRY_RUN=1 to preview)"
  task backfill: :environment do
    dry_run = ENV["DRY_RUN"].present?
    changed = 0
    options = 0

    # Drafts only. The hoist itself already refuses to touch a published Verto
    # (an option label is the answer key for responses already collected); this
    # scope just avoids loading them at all.
    Survey.kept.where(published_at: nil).find_each do |survey|
      before = survey.cards
      after  = Survey.hoist_option_label_emoji!(before)
      next if after == before

      moved = after.each_with_index.sum do |card, i|
        Array(card["options"]).zip(Array(before[i]["options"])).count { |now, was| now != was }
      end
      changed += 1
      options += moved
      puts "  #{survey.id} #{survey.title.to_s.truncate(48)} — #{moved} option(s)"
      survey.update_column(:cards, after) unless dry_run
    end

    puts ""
    puts "#{dry_run ? '[DRY RUN] ' : ''}vertos updated: #{changed}"
    puts "options whose emoji moved into the tile: #{options}"
  end
end
