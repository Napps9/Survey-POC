# Replaces Rails' stock rails/health#show, which only proves the process can
# route a request. Render's healthCheckPath hits this frequently, so it stays
# a plain ActionController::Base (not ApplicationController — no auth/org
# scoping/locale overhead belongs on a prober endpoint).
class HealthController < ActionController::Base
  def show
    ActiveRecord::Base.with_connection(&:verify!)
    head :ok
  rescue ActiveRecord::ConnectionTimeoutError => e
    # Pool exhaustion means BUSY, not dead. Under a burst every instance can
    # be briefly out of connections at once; failing the health check here
    # made Render restart healthy instances exactly when capacity mattered
    # most — a saturation cascade. The process is alive and will recover as
    # requests drain; report OK and leave the alarm to the log line.
    Rails.logger.error("[HealthCheck] pool saturated: #{e.message}")
    head :ok
  rescue => e
    # A hard failure (bad credentials, DB genuinely down/unreachable) still
    # fails the check — a container that can't ever reach the database should
    # not enter or stay in rotation.
    Rails.logger.error("[HealthCheck] #{e.class}: #{e.message}")
    head :service_unavailable
  end
end
