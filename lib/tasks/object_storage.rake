# Active Storage disk → bucket cutover tooling. Runbook: docs/OBJECT_STORAGE_CUTOVER.md.
#
# FROM / TO name services in config/storage.yml (default local → bucket).
# DRY_RUN=1 previews without copying or flipping anything. Every task prints
# what it did; `migrate` exits non-zero if any blob failed or was missing so a
# shell session can't miss it.
module ObjectStorageRake
  module_function

  def migrator
    from = ENV.fetch("FROM", "local")
    to   = ENV.fetch("TO", "bucket")
    if to == "bucket" && ENV["STORAGE_BUCKET"].blank?
      abort "TO=bucket but STORAGE_BUCKET is blank — set the STORAGE_* vars first (docs/OBJECT_STORAGE_CUTOVER.md)"
    end
    ObjectStorage::Migrator.new(from: from, to: to, dry_run: ENV["DRY_RUN"] == "1")
  end
end

namespace :object_storage do
  desc "Counts of Active Storage blobs per service (the before/after picture)"
  task status: :environment do
    counts = ObjectStorage::Migrator.status
    puts "app writes new uploads to: #{ObjectStorage.service_name}"
    puts "no blobs" if counts.empty?
    counts.sort_by { |name, _| name.to_s }.each { |name, n| puts "  #{name.to_s.ljust(12)} #{n}" }
  end

  desc "Copy blobs FROM=local TO=bucket, flipping each as it lands (DRY_RUN=1 to preview). Idempotent — re-run to sweep stragglers."
  task migrate: :environment do
    result = ObjectStorageRake.migrator.run!
    abort "object_storage:migrate finished WITH PROBLEMS — #{result}" unless result.ok?
  end

  desc "Confirm nothing is left on FROM and that a random sample of TO's blobs really exists"
  task verify: :environment do
    abort "object_storage:verify FAILED — see the line above" unless ObjectStorageRake.migrator.verify
    puts "verify OK"
  end

  desc "Point blobs on TO back at FROM wherever FROM still has the bytes (DRY_RUN=1 to preview)"
  task rollback: :environment do
    ObjectStorageRake.migrator.rollback!
  end
end
