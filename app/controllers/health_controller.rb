# Replaces Rails' stock rails/health#show, which only proves the process can
# route a request. Render's healthCheckPath hits this frequently, so it stays
# a plain ActionController::Base (not ApplicationController — no auth/org
# scoping/locale overhead belongs on a prober endpoint).
class HealthController < ActionController::Base
  def show
    ActiveRecord::Base.with_connection(&:verify!)
    head :ok
  rescue => e
    Rails.logger.error("[HealthCheck] #{e.class}: #{e.message}")
    head :service_unavailable
  end
end
