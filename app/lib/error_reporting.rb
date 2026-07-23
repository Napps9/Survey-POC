# Shared entry point for the app's existing `rescue => e` convention (log a
# tagged one-liner and move on — see any controller/service for examples).
# Reports to Sentry too when it's configured; always logs regardless, so
# behavior in dev/test (no SENTRY_DSN) is unchanged from a bare
# Rails.logger.error call.
module ErrorReporting
  module_function

  def report(tag, exception, **context)
    Rails.logger.error("[#{tag}] #{exception.class}: #{exception.message}")

    # Sentry.init runs on every boot (config/initializers/sentry.rb), so
    # Sentry.initialized? is true even with no SENTRY_DSN - it just falls
    # back to a no-op DummyTransport internally. Check the DSN directly
    # instead, so dev/test skip the capture pipeline entirely rather than
    # silently building events nothing will send.
    return unless defined?(Sentry) && Sentry.configuration&.dsn

    Sentry.capture_exception(exception) do |scope|
      scope.set_tags(component: tag)
      scope.set_extras(context) if context.present?
    end
  end
end
