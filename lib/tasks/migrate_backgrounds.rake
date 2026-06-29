namespace :backgrounds do
  # One-off: move existing base64 Verto backgrounds out of the surveys row and
  # into Active Storage (object storage), replacing background_image with the
  # blob URL. Idempotent — rows already on an asset/blob URL are skipped, so it's
  # safe to re-run. Run once after deploying the object-storage change (and after
  # ACTIVE_STORAGE_SERVICE/R2 are configured, so blobs land in R2).
  desc "Move base64 Verto backgrounds into Active Storage"
  task migrate: :environment do
    helpers  = Rails.application.routes.url_helpers
    migrated = 0
    failed   = 0

    Survey.where("background_image LIKE 'data:image/%'").find_each do |survey|
      m = survey.background_image.to_s.match(%r{\Adata:(image/[\w.+-]+);base64,(.+)\z}m)
      next unless m

      content_type = m[1]
      bytes        = Base64.decode64(m[2])
      ext          = content_type.split("/").last.sub("jpeg", "jpg").sub("svg+xml", "svg")

      survey.background_file.attach(io: StringIO.new(bytes), filename: "background.#{ext}", content_type: content_type)
      survey.update_column(:background_image, helpers.rails_blob_path(survey.background_file, only_path: true))
      migrated += 1
      print "."
    rescue => e
      failed += 1
      warn "\n[backgrounds:migrate] survey ##{survey.id}: #{e.class}: #{e.message}"
    end

    puts "\nMigrated #{migrated} background(s)#{failed.positive? ? ", #{failed} failed" : ''}."
  end
end
