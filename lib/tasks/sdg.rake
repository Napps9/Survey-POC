namespace :sdg do
  desc "Tag existing Vertos with UN SDGs via SdgClassifier (DRY_RUN=1 to preview, FORCE=1 to re-tag already-tagged Vertos)"
  task backfill: :environment do
    classifier = SdgClassifier.new
    abort "ANTHROPIC_API_KEY is not set — SDG classification needs a key." unless classifier.configured?

    dry_run = ENV["DRY_RUN"].present?
    force   = ENV["FORCE"].present?
    tagged  = 0
    skipped = 0
    empty   = 0

    # Every live Verto, whatever its origin — imports, seeds, editor drafts.
    # Archived Vertos are on their way out; a restore plus FORCE=1 re-tags.
    Survey.kept.find_each do |survey|
      # Already tagged means a real verdict was stored (including []), but the
      # column default is also [] — so "already tagged" can only mean
      # non-empty. FORCE re-runs everything; without it, an empty list is
      # re-judged, which is cheap and self-heals earlier failed runs.
      if survey.sdgs.any? && !force
        skipped += 1
        next
      end
      # Nothing to classify — no deck and no framing text.
      next if Array(survey.cards).empty? && survey.title.blank? && survey.theme.blank?

      sdgs = classifier.call(survey: survey)
      empty += 1 if sdgs.empty?
      tagged += 1
      labels = sdgs.any? ? sdgs.map { |n| UnSdgs.label(n) }.join(", ") : "none"
      puts "  #{survey.id} #{survey.title.to_s.truncate(48)} — #{labels}"
      survey.update_column(:sdgs, sdgs) unless dry_run
    end

    puts ""
    puts "#{dry_run ? '[DRY RUN] ' : ''}vertos classified: #{tagged} (#{empty} with no applicable goal)"
    puts "skipped as already tagged: #{skipped}#{' (use FORCE=1 to re-tag)' if skipped.positive?}"
  end
end
