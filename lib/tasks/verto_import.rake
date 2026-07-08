namespace :verto do
  desc "Import a Verto (account + reconstructed questions + responses) from a " \
       "response-level CSV export of another survey platform. Idempotent — " \
       "rebuilds only the target org's data. Requires IMPORT_PASSWORD (12+ chars). " \
       "Optional: IMPORT_ORG_NAME, IMPORT_ORG_SLUG, IMPORT_ADMIN_EMAIL, IMPORT_TITLE, IMPORT_VERTO_SLUG. " \
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
      org_name:       ENV.fetch("IMPORT_ORG_NAME", VertoCsvImporter::DEFAULT_ORG_NAME),
      org_slug:       ENV.fetch("IMPORT_ORG_SLUG", VertoCsvImporter::DEFAULT_ORG_SLUG),
      admin_email:    ENV.fetch("IMPORT_ADMIN_EMAIL", VertoCsvImporter::DEFAULT_ADMIN_EMAIL),
      title:          ENV.fetch("IMPORT_TITLE", VertoCsvImporter::DEFAULT_TITLE),
      verto_slug:     ENV.fetch("IMPORT_VERTO_SLUG", VertoCsvImporter::DEFAULT_VERTO_SLUG)
    )
    survey = importer.call

    puts "── Verto CSV import complete ──"
    importer.summary_for(survey).each { |k, v| puts format("  %-10s %s", "#{k}:", v) }
    puts "  login pw:  the value you set in IMPORT_PASSWORD"
  end

  desc "Remove an imported Verto account (org + admin + Verto + responses). " \
       "Honours IMPORT_ORG_SLUG / IMPORT_ADMIN_EMAIL (defaults to the UNYO import)."
  task destroy_import: :environment do
    VertoCsvImporter.new(
      csv_path:       "/dev/null",
      admin_password: "x" * 12,
      org_slug:       ENV.fetch("IMPORT_ORG_SLUG", VertoCsvImporter::DEFAULT_ORG_SLUG),
      admin_email:    ENV.fetch("IMPORT_ADMIN_EMAIL", VertoCsvImporter::DEFAULT_ADMIN_EMAIL)
    ).destroy!
    puts "Removed imported Verto account (#{ENV.fetch('IMPORT_ORG_SLUG', VertoCsvImporter::DEFAULT_ORG_SLUG)})."
  end
end
