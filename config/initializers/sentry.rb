# Error tracking. The Sentry ORGANISATION (not this config) is what pins data
# residency to the EU/Frankfurt region — it's chosen once, irreversibly, when
# the org is created, and every DSN under it inherits that region. See
# docs/DEPLOYMENT_RUNBOOK.md for the one-time setup. Safe to load with no
# SENTRY_DSN (dev/test): Sentry.init no-ops and every ErrorReporting.report
# call falls back to logging only — see app/lib/error_reporting.rb.
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = Rails.env
  config.enabled_environments = %w[production]
  config.release = ENV["RENDER_GIT_COMMIT"] # Render-injected; ties events to a deploy
  config.send_default_pii = false
  config.breadcrumbs_logger = [ :active_support_logger ]

  # send_default_pii alone does not scrub request body/params. Respondent
  # birth date/location ride through PlayerController's hand-parsed JSON
  # bodies under dynamic per-card keys, so name-based filtering can't catch
  # them either — strip request data outright instead.
  config.before_send = lambda do |event, _hint|
    if event.request
      event.request.data = nil
      event.request.query_string = nil
      event.request.cookies = nil
    end
    event
  end
end

if Rails.env.production? && ENV["SENTRY_DSN"].blank?
  Rails.logger.warn(
    "[Sentry] SENTRY_DSN is not set — errors will not be reported. " \
    "Set it in the Render dashboard (see .env.example)."
  )
end
