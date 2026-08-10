# Everything the import did not store exactly as the file had it.
#
# Printed after every run, because the promise this importer makes is that a
# cited figure came from the question and the people it says it did. A
# transformation nobody can see is indistinguishable from a mistake, so all
# three tallies are surfaced: values the deck did not recognise, values it
# recognised and did not store, and values it stored with a caveat.
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

  importer.inferred.each do |col, values|
    puts "  ADDED (not in the file) in #{col}:"
    values.sort_by { |_v, n| -n }.first(10).each { |v, n| puts "    #{n}× #{v}" }
  end

  importer.notes.each do |col, values|
    puts "  STORED, WITH A NOTE, in #{col}:"
    values.sort_by { |_v, n| -n }.first(10).each { |v, n| puts "    #{n}× #{v}" }
  end

  puts "  #{importer.rows_without_id} rows had no Viewing ID and could not be replayed." if importer.rows_without_id.positive?
end

# Which source survey this export is, and the identity that goes with it.
#
# The deck already knows the account, title and slug it belongs to, so only an
# override that is actually SET is passed on — handing the importer a nil (or,
# as this task used to, the UNYouth constants) would quietly file every deck
# under the same organisation.
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

  desc "Read-only check of the database an import is about to be run against. " \
       "Reports the schema version, what each importable deck's account currently " \
       "holds (and whether any of it was collected through the player rather than " \
       "imported), the database size, and whether the Anthropic key works. " \
       "Exits non-zero on anything that should stop a run. " \
       "Usage: bin/rails verto:preflight"
  task preflight: :environment do
    ok = true
    puts "── Preflight: #{ActiveRecord::Base.connection.adapter_name} " \
         "#{ActiveRecord::Base.connection_db_config.database} ──"

    # ── schema ──────────────────────────────────────────────────────────────
    # An import writes columns that a stale database does not have. Better to
    # say so here than to fail 90,000 rows in.
    pending = ActiveRecord::Base.connection_pool.migration_context.needs_migration?
    puts "  schema:    #{ActiveRecord::Migrator.current_version}#{pending ? '  ← MIGRATIONS PENDING' : ''}"
    ok &&= !pending

    # ── what is already there ───────────────────────────────────────────────
    puts "  accounts:"
    VertoDecks.available.map { |key| VertoDecks.fetch(key) }.group_by(&:org_slug).each do |slug, decks|
      org = Organisation.find_by(slug: slug)
      if org.nil?
        puts format("    %-16s absent — will be created by %s", slug, decks.map(&:key).join(", "))
        next
      end

      responses = Response.where(survey: org.surveys)
      # A response whose token this importer did not mint was collected through
      # the player. "Rebuild the account" is a decision about IMPORTED data;
      # organic answers are somebody's actual respondents and are not ours to
      # replace on a rule.
      prefixes = decks.map { |d| "#{[ slug, d.collection_mode ].compact.join('-')}-" }
      organic  = responses.reject { |r| prefixes.any? { |p| r.session_token.to_s.start_with?(p) } }

      puts format("    %-16s %d Verto(s), %d responses%s", slug, org.surveys.kept.count, responses.count,
                  organic.any? ? "  ← #{organic.size} NOT from an import" : "")
      ok = false if organic.any?
    end

    # ── room ────────────────────────────────────────────────────────────────
    if ActiveRecord::Base.connection.adapter_name.match?(/postg/i)
      size = ActiveRecord::Base.connection.select_value(
        "SELECT pg_size_pretty(pg_database_size(current_database()))")
      puts "  db size:   #{size} (plan limit is not visible from here — check the dashboard)"
    end
    puts "  projected: ~0.5GB of responses once all five imports have run"

    # ── the key, before 200 batches discover it is wrong ────────────────────
    themer = OpenTextThemer.new
    if !themer.configured?
      puts "  anthropic: NO KEY — closed questions would still index, themes and quotes would not"
    else
      begin
        themer.call(question_text: "preflight", texts: Array.new(CorpusEntry.min_sample_size + 1) { "ping" })
        puts "  anthropic: key works"
      rescue => e
        puts "  anthropic: KEY FAILED — #{e.class}: #{e.message.to_s.first(120)}"
        ok = false
      end
    end

    puts ok ? "  READY" : "  NOT READY — see the marked lines above."
    abort "Preflight failed." unless ok
  end

  desc "Check that an imported Verto still says what its export said. For every " \
       "question column: atoms in the source == values stored + values the import " \
       "reported as not stored. Reads the source as raw text rather than through the " \
       "deck, so a spec that loses an answer cannot also hide it. Exits non-zero on a " \
       "difference, so CI can run it. " \
       "Usage: IMPORT_DECK=<deck> bin/rails 'verto:reconcile[db/seeds/exports/<file>.csv.gz]'"
  task :reconcile, [ :path ] => :environment do |_t, args|
    path = args[:path] || ENV["CSV_PATH"]
    abort "usage: bin/rails 'verto:reconcile[path/to/export.csv.gz]'" if path.blank?
    abort "Export not found: #{path}" unless File.exist?(path)

    importer = VertoCsvImporter.new(csv_path: path, **deck_identity)
    org      = Organisation.find_by(slug: importer.org_slug)
    abort "No organisation '#{importer.org_slug}' — run verto:import_csv first." unless org

    survey = org.surveys.kept.find_by(slug: importer.verto_slug) || org.surveys.kept.order(:id).first
    abort "No Verto found in '#{importer.org_slug}'." unless survey

    report = VertoReconciler.new(importer, survey).call

    puts "── Reconciling #{survey.title} against #{File.basename(path)} ──"
    puts format("  %-46s %8s %8s %8s %8s %6s", "question", "source", "stored", "reported", "inferred", "diff")
    report.lines.each do |line|
      puts format("  %-46s %8d %8d %8d %8d %6d%s",
                  line.question.to_s[0, 46], line.source, line.stored, line.reported, line.inferred,
                  line.difference, line.clean? ? "" : "  ← UNACCOUNTED")
    end

    puts
    puts "  rows read:  #{report.rows}"
    puts "  responses:  #{report.responses}#{" (#{report.rows_without_id} rows had no Viewing ID)" if report.rows_without_id.positive?}"

    if report.clean?
      puts "  RECONCILED — every answer in the export is either stored or accounted for."
    else
      puts "  #{report.problems.size} column(s) do not add up:"
      report.problems.each do |line|
        puts "    #{line.column}"
        line.missing.each { |col| puts "      MISSING COLUMN: #{col}" }
        puts "      #{line.difference} source answers are neither stored nor reported." unless line.difference.zero?
        line.labels.sort_by { |_v, n| -n }.first(8).each { |value, n| puts "        #{n}× #{value.inspect}" }
      end
      abort "Reconciliation FAILED. The Verto does not account for everything its export holds."
    end
  end

  desc "Rewrite db/seeds/exports/manifest.yml from the files that are there. " \
       "Records each export's source workbook, sheet, row and column counts and the " \
       "SHA-256 of its decompressed bytes — which the importer checks before reading, " \
       "so a citation always traces to a file whose contents are known. " \
       "Run it after adding or replacing an export, and commit the result."
  task manifest: :environment do
    existing = ExportManifest.entries
    out = {}

    Dir[ExportManifest::DIR.join("*.csv.gz")].sort.each do |path|
      name  = File.basename(path)
      shape = ExportManifest.shape(path)
      # Provenance is human knowledge and is never overwritten — only the
      # digest and the counts are re-derived from the file.
      out[name] = (existing[name] || { "source" => "UNKNOWN — fill this in", "sheet" => "", "conversion" => "" })
                    .merge(shape).merge("sha256" => ExportManifest.digest(path))
      puts format("  %-58s %7d rows × %2d cols", name, shape["rows"], shape["columns"])
    end

    File.write(ExportManifest::FILE, <<~HEADER + out.to_yaml.sub(/\A---\n/, ""))
      # What each committed export is, and proof that it still is.
      #
      # `sha256` is of the DECOMPRESSED bytes, so re-gzipping at a different
      # compression level does not read as a different dataset. VertoCsvImporter
      # checks it before reading a row and refuses a file that does not match:
      # a silently edited export would otherwise import cleanly, move every
      # number, and say nothing about why.
      #
      # Regenerate with: bin/rails verto:manifest
    HEADER
    puts "Wrote #{ExportManifest::FILE.relative_path_from(Rails.root)} (#{out.size} exports)."
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

    result = CorpusEnrolment.new(survey, user: admin, reviewer: admin.email_address).call

    puts "── Ask Verto enrolment ──"
    puts "  verto:     #{survey.title}"
    puts "  offered:   yes (by #{admin.email_address})"
    puts "  approved:  #{result.approved? ? "yes — #{result.questions} questions indexed" : 'NO'}"
    result.blocked_by.each { |label| puts "  BLOCKED:   #{label} — left in the staff review queue" }
    result.warnings.each   { |label| puts "  warning:   #{label}" }
  end
end
