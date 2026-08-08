# Which source survey this export is, and the identity that goes with it.
#
# The deck already knows the account, title and slug it belongs to, so only an
# override that is actually SET is passed on — handing the importer a nil (or,
# as this task used to, the UNYouth constants) would quietly file every deck
# under the same organisation.
# Everything the import did NOT store exactly as the file had it.
#
# Printed after every run, because the promise this importer makes is that a
# cited figure came from the question and the people it says it did. A
# transformation nobody can see is indistinguishable from a mistake, so both
# tallies are surfaced even when they are empty.
def report_variances(importer)
  importer.unmatched.each do |col, values|
    puts "  UNMATCHED in #{col}:"
    values.sort_by { |_v, n| -n }.first(10).each { |v, n| puts "    #{n}× #{v.inspect}" }
    puts "    …the deck's option list does not contain these. Add them, or map them in " \
         "<csv>.translations.yml (translated label → English option), and re-run."
  end

  importer.dropped.each do |col, values|
    puts "  NOT STORED in #{col}:"
    values.sort_by { |_v, n| -n }.first(10).each { |v, n| puts "    #{n}× #{v}" }
  end

  puts "  #{importer.rows_without_id} rows had no Viewing ID and could not be replayed." if importer.rows_without_id.positive?
end

def deck_identity
  {
    deck:        ENV.fetch("IMPORT_DECK", VertoDecks::DEFAULT),
    org_name:    ENV["IMPORT_ORG_NAME"],
    org_slug:    ENV["IMPORT_ORG_SLUG"],
    admin_email: ENV["IMPORT_ADMIN_EMAIL"],
    title:       ENV["IMPORT_TITLE"],
    verto_slug:  ENV["IMPORT_VERTO_SLUG"]
  }.compact
end

namespace :verto do
  desc "Import a Verto (account + reconstructed questions + responses) from a " \
       "response-level CSV export of another survey platform. Idempotent — " \
       "rebuilds only the target org's data. Requires IMPORT_PASSWORD (12+ chars). " \
       "IMPORT_DECK names which source survey this export is (see VertoDecks.available); " \
       "it supplies the account and question deck, so the IMPORT_ORG_NAME / IMPORT_ORG_SLUG / " \
       "IMPORT_ADMIN_EMAIL / IMPORT_TITLE / IMPORT_VERTO_SLUG overrides are only needed to " \
       "put one somewhere else. " \
       "Usage: bin/rails 'verto:import_csv[db/seeds/unyo_sport_x_changemaking_2026.csv]'"
  task :import_csv, [ :path ] => :environment do |_t, args|
    path = args[:path] || ENV["CSV_PATH"]
    abort "usage: bin/rails 'verto:import_csv[path/to/export.csv]'" if path.blank?
    abort "CSV not found: #{path}" unless File.exist?(path)
    if ENV["IMPORT_PASSWORD"].to_s.length < 12
      abort "Set IMPORT_PASSWORD (12+ characters) before running this task, e.g.:\n" \
            "  IMPORT_PASSWORD='a-strong-passphrase' bin/rails 'verto:import_csv[#{path}]'"
    end

    importer = VertoCsvImporter.new(
      csv_path:       path,
      admin_password: ENV["IMPORT_PASSWORD"],
      **deck_identity
    )
    survey = importer.call

    puts "── Verto CSV import complete ──"
    importer.summary_for(survey).each { |k, v| puts format("  %-10s %s", "#{k}:", v) }
    puts "  login pw:  the value you set in IMPORT_PASSWORD"
    report_variances(importer)
  end

  desc "Append/refresh a CSV export into the EXISTING imported Verto without " \
       "rebuilding it — adds responses new to the export and updates ones already " \
       "imported, leaving the account, Verto (and its /play link) and any organic " \
       "responses untouched. No password needed. Honours IMPORT_ORG_SLUG / IMPORT_VERTO_SLUG. " \
       "Usage: bin/rails 'verto:append_csv[db/seeds/unyo_sport_x_changemaking_2026.csv]'"
  task :append_csv, [ :path ] => :environment do |_t, args|
    path = args[:path] || ENV["CSV_PATH"]
    abort "usage: bin/rails 'verto:append_csv[path/to/export.csv]'" if path.blank?
    abort "CSV not found: #{path}" unless File.exist?(path)

    importer = VertoCsvImporter.new(csv_path: path, **deck_identity)
    result = importer.append!

    puts "── Verto CSV append complete ──"
    puts "  added:     #{result[:added]} new responses"
    puts "  updated:   #{result[:updated]} existing responses"
    importer.summary_for(result[:survey]).each { |k, v| puts format("  %-10s %s", "#{k}:", v) }
    report_variances(importer)
  end

  desc "Build a Verto from a deck alone, with no export to replay — for a deck " \
       "we have the questions for but not the answers. Creates the account and the " \
       "playable Verto, nothing else. Requires IMPORT_DECK and IMPORT_PASSWORD (12+ chars). " \
       "Usage: IMPORT_DECK=walls_happiness_child bin/rails verto:build_deck"
  task build_deck: :environment do
    if ENV["IMPORT_PASSWORD"].to_s.length < 12
      abort "Set IMPORT_PASSWORD (12+ characters) before running this task."
    end
    abort "Set IMPORT_DECK to one of: #{VertoDecks.available.join(', ')}" if ENV["IMPORT_DECK"].blank?

    importer = VertoCsvImporter.new(csv_path: "/dev/null", admin_password: ENV["IMPORT_PASSWORD"],
                                    **deck_identity)
    survey = importer.build!

    puts "── Verto built from deck '#{ENV['IMPORT_DECK']}' ──"
    puts "  org:       #{importer.org_slug}"
    puts "  title:     #{survey.title}"
    puts "  cards:     #{survey.cards.size}"
    puts "  play_link: /play/#{survey.slug || survey.publish_token}"
    puts "  responses: none — this deck has questions but no answers yet, so it " \
         "contributes nothing to Ask Verto until it has been fielded."
  end

  desc "Remove an imported Verto account (org + admin + Verto + responses). " \
       "Honours IMPORT_ORG_SLUG / IMPORT_ADMIN_EMAIL (defaults to the UNYO import)."
  task destroy_import: :environment do
    importer = VertoCsvImporter.new(csv_path: "/dev/null", admin_password: "x" * 12, **deck_identity)
    importer.destroy!
    puts "Removed imported Verto account (#{importer.org_slug})."
  end

  desc "Offer an imported Verto to Ask Verto and approve it, for data VertoNow " \
       "imports under an agreement rather than data a customer offers in the editor. " \
       "Turns both consent keys and indexes the corpus. A Verto the automated checks " \
       "BLOCK is offered but left in the staff queue — it is never auto-approved. " \
       "Honours IMPORT_DECK / IMPORT_ORG_SLUG / IMPORT_VERTO_SLUG."
  task enrol_corpus: :environment do
    importer = VertoCsvImporter.new(csv_path: "/dev/null", admin_password: "x" * 12, **deck_identity)
    org = Organisation.find_by(slug: importer.org_slug)
    abort "No organisation '#{importer.org_slug}' — run verto:import_csv first." unless org

    survey = org.surveys.kept.find_by(slug: importer.verto_slug) || org.surveys.kept.order(:id).first
    abort "No Verto found in '#{importer.org_slug}'." unless survey

    admin = org.memberships.order(:id).first&.user
    abort "No member of '#{importer.org_slug}' to record as the creator." unless admin

    result = CorpusEnrolment.new(survey, user: admin, reviewer: admin).call

    puts "── Ask Verto enrolment ──"
    puts "  verto:     #{survey.title}"
    puts "  offered:   yes (by #{admin.email_address})"
    puts "  approved:  #{result.approved? ? "yes — #{result.questions} questions indexed" : 'NO'}"
    result.blocked_by.each { |label| puts "  BLOCKED:   #{label} — left in the staff review queue" }
    result.warnings.each   { |label| puts "  warning:   #{label}" }
  end
end
