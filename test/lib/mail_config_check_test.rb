require "test_helper"
require Rails.root.join("lib/mail_config_check")

# The check itself, driven with an explicit env hash rather than by booting a
# production app — same approach as memory_watchdog_test.
class MailConfigCheckTest < ActiveSupport::TestCase
  GOOD = { "SMTP_ADDRESS" => "smtp-relay.brevo.com", "APP_HOST" => "playverto.com" }.freeze

  class NullLogger
    attr_reader :warnings
    def initialize = @warnings = []
    def warn(msg) = @warnings << msg
  end

  test "a fully configured environment has no problems" do
    assert_empty MailConfigCheck.problems(GOOD)
  end

  test "RENDER_EXTERNAL_HOSTNAME satisfies the host requirement on its own" do
    # Render injects it automatically, so a deploy with no custom domain is
    # correctly configured and must not be flagged.
    env = { "SMTP_ADDRESS" => "smtp.example.com", "RENDER_EXTERNAL_HOSTNAME" => "app.onrender.com" }
    assert_empty MailConfigCheck.problems(env)
  end

  test "a missing SMTP_ADDRESS is a problem" do
    problems = MailConfigCheck.problems(GOOD.except("SMTP_ADDRESS"))
    assert_equal 1, problems.size
    assert_match(/SMTP_ADDRESS/, problems.first)
    assert_match(/password resets/, problems.first,
                 "the message should name what actually breaks, not just the variable")
  end

  test "a missing host is a problem" do
    problems = MailConfigCheck.problems(GOOD.except("APP_HOST"))
    assert_equal 1, problems.size
    assert_match(/APP_HOST/, problems.first)
  end

  test "blank and whitespace-only values count as missing" do
    # Render's dashboard makes an empty string easy to create, and `if host`
    # in the initializer treats "" as truthy — so a blank would otherwise sail
    # through both the check and the config it is guarding.
    [ "", "   ", "\t" ].each do |blank|
      assert_equal 1, MailConfigCheck.problems(GOOD.merge("SMTP_ADDRESS" => blank)).size,
                   "#{blank.inspect} should count as unset"
    end
  end

  test "an empty environment reports both problems" do
    assert_equal 2, MailConfigCheck.problems({}).size
  end

  test "run! logs and reports rather than raising by default" do
    logger = NullLogger.new
    reported = []
    stub_method(ErrorReporting, :report, ->(tag, error, **) { reported << [ tag, error ] }) do
      assert_nothing_raised { MailConfigCheck.run!({}, logger: logger) }
    end

    assert_equal 1, logger.warnings.size
    assert_equal 1, reported.size
    assert_equal "MailConfig", reported.first.first
    assert_kind_of MailConfigCheck::MisconfiguredError, reported.first.last
  end

  test "run! is silent when everything is configured" do
    logger = NullLogger.new
    reported = []
    stub_method(ErrorReporting, :report, ->(*_a, **_k) { reported << true }) do
      MailConfigCheck.run!(GOOD, logger: logger)
    end
    assert_empty logger.warnings
    assert_empty reported, "a healthy configuration must not page anyone"
  end

  test "STRICT_MAIL_CONFIG turns the report into a boot failure" do
    error = assert_raises(RuntimeError) do
      MailConfigCheck.run!({ "STRICT_MAIL_CONFIG" => "1" }, logger: NullLogger.new)
    end
    assert_match(/SMTP_ADDRESS/, error.message)
  end

  test "strict mode still boots when the configuration is good" do
    # The flag must be safe to leave on — otherwise nobody will turn it on.
    assert_nothing_raised do
      MailConfigCheck.run!(GOOD.merge("STRICT_MAIL_CONFIG" => "1"), logger: NullLogger.new)
    end
  end

  test "the strict flag accepts the usual truthy spellings and nothing else" do
    assert MailConfigCheck.strict?("STRICT_MAIL_CONFIG" => "1")
    assert MailConfigCheck.strict?("STRICT_MAIL_CONFIG" => "true")
    assert MailConfigCheck.strict?("STRICT_MAIL_CONFIG" => "TRUE")
    assert MailConfigCheck.strict?("STRICT_MAIL_CONFIG" => "yes")
    refute MailConfigCheck.strict?("STRICT_MAIL_CONFIG" => "0")
    refute MailConfigCheck.strict?("STRICT_MAIL_CONFIG" => "false")
    refute MailConfigCheck.strict?("STRICT_MAIL_CONFIG" => "")
    refute MailConfigCheck.strict?({})
  end

  # ── Can this deployment actually send right now? ──────────────────────────

  test "a delivery method other than SMTP is always deliverable" do
    # :test here, :file or a local catcher in development. All of them deliver
    # as intended and none of them has an SMTP_ADDRESS, so reading the variable
    # alone would call a working suite broken.
    assert_equal :test, ActionMailer::Base.delivery_method,
                 "this test is only meaningful while the suite delivers to :test"
    assert MailConfigCheck.deliverable?({})
  end

  test "SMTP with no address behind it is not deliverable" do
    # Rails' bare default — :smtp at localhost:25 — which is exactly what a
    # Render deploy runs with when SMTP_ADDRESS was never entered in the
    # dashboard. Every send fails, and every caller used to report success.
    with_delivery_method(:smtp) do
      refute MailConfigCheck.deliverable?({})
      refute MailConfigCheck.deliverable?("SMTP_ADDRESS" => "   "),
             "blank counts as unset here for the same reason it does in #problems"
      assert MailConfigCheck.deliverable?(GOOD)
    end
  end

  test "deliverable? is narrower than problems — a missing host does not block the send" do
    # A missing APP_HOST breaks link building INSIDE the job, where the caller's
    # own rescue reports it. Treating it as undeliverable here would refuse to
    # enqueue mail that a RENDER_EXTERNAL_HOSTNAME-only deploy sends perfectly.
    env = { "SMTP_ADDRESS" => "smtp.example.com" }
    with_delivery_method(:smtp) { assert MailConfigCheck.deliverable?(env) }
    assert_equal 1, MailConfigCheck.problems(env).size
  end

  # The reason the call lives in after_initialize rather than the initializer
  # body. Initializers run alphabetically, so `mailer` runs before `sentry` and
  # Sentry.configuration is still nil there — the report would have been
  # swallowed by exactly the silence it exists to break.
  test "the check runs after initialization, not inside the mailer initializer" do
    source = File.read(Rails.root.join("config/initializers/mailer.rb"))
    assert_match(/after_initialize\s*\{\s*MailConfigCheck\.run!/, source)
    assert_operator Dir[Rails.root.join("config/initializers/*.rb")].map { |f| File.basename(f) }.sort
                        .index("mailer.rb"), :<,
                    Dir[Rails.root.join("config/initializers/*.rb")].map { |f| File.basename(f) }.sort
                        .index("sentry.rb"),
                    "if sentry.rb ever sorts before mailer.rb this indirection is no longer needed"
  end

  private

  def with_delivery_method(method)
    was = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = method
    yield
  ensure
    ActionMailer::Base.delivery_method = was
  end
end
