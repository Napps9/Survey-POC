# Runtime view of where Active Storage keeps its bytes.
#
# The `bucket` service in config/storage.yml is env-driven (credentials +
# endpoint) and production selects it with ACTIVE_STORAGE_SERVICE=bucket
# (config/environments/production.rb). The two are deliberately separate: the
# bucket is CONFIGURED first, so ObjectStorage::Migrator can copy into it while
# the app still writes to the local disk, and only ACTIVATED once every blob is
# across. This module is the one place the rest of the app asks which side of
# that line it is on. Cutover: docs/OBJECT_STORAGE_CUTOVER.md.
module ObjectStorage
  module_function

  # The service new uploads go to (:local on the Render disk, :bucket after).
  def service_name
    Rails.application.config.active_storage.service
  end

  # True once uploads land in the shared bucket — the only posture in which
  # more than one web instance (or the worker) can serve every attachment.
  def bucket_active?
    service_name == :bucket
  end

  # True when the bucket has credentials, active or not.
  def bucket_configured?
    ENV["STORAGE_BUCKET"].present?
  end
end
