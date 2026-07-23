require "test_helper"

class ErrorReportingTest < ActiveSupport::TestCase
  test "always logs in the existing [Tag] Class: message format" do
    logged = nil
    stub_method(Rails.logger, :error, ->(msg) { logged = msg }) do
      ErrorReporting.report("Test", RuntimeError.new("boom"))
    end
    assert_equal "[Test] RuntimeError: boom", logged
  end

  test "reports to Sentry only when a DSN is configured" do
    fake_config = Struct.new(:dsn).new("https://fake@example.com/1")
    captured = nil
    stub_method(Sentry, :configuration, fake_config) do
      stub_method(Sentry, :capture_exception, ->(e, &_blk) { captured = e }) do
        ErrorReporting.report("Test", RuntimeError.new("boom"))
      end
    end
    assert_equal "boom", captured.message
  end

  test "skips Sentry when no DSN is configured (the real dev/test default)" do
    # No stubbing here on purpose: Sentry.init runs on every boot regardless
    # of environment, so Sentry.initialized? is true in test too - this
    # exercises the actual guard (Sentry.configuration&.dsn) against the
    # real test-env config, which genuinely has no SENTRY_DSN set.
    assert_nil Sentry.configuration&.dsn
    assert_nothing_raised { ErrorReporting.report("Test", RuntimeError.new("boom")) }
  end
end
