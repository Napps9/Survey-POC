# Separate from HealthController (/up) on purpose: Render's own
# healthCheckPath hits /up frequently and restarts the service on repeated
# failure there, so a disk-mount check does NOT belong on that path — a
# brief window early in a fresh container's boot, or Render's own transient
# hiccup, would trip a restart loop over a check whose whole point is to be
# checked occasionally by something external, not by Render itself.
#
# Unauthenticated like /up: it reveals nothing but a boolean, and whatever
# polls it (a Routine, an uptime monitor) has no session to authenticate
# with anyway.
class StorageHealthController < ActionController::Base
  def show
    if StorageMountCheck.mounted?
      render json: { mounted: true }
    else
      Rails.logger.error("[StorageHealthCheck] /rails/storage is not a separate mount — " \
                          "uploads will not survive the next deploy or restart.")
      render json: { mounted: false }, status: :service_unavailable
    end
  end
end
