require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # config.public_file_server.enabled = false

  # Compress CSS using a preprocessor.
  # config.assets.css_compressor = :sass

  # Do not fall back to assets pipeline if a precompiled asset is missed.
  config.assets.compile = false

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  # config.action_cable.url = "wss://example.com/cable"
  # config.action_cable.allowed_request_origins = [ "http://example.com", /http:\/\/example.*/ ]

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # "info" includes generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). If you
  # want to log everything, set the level to "debug".
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Rails.cache — and with it every `rate_limit` counter, because `rate_limit`
  # resolves `store:` from ActionController::Base.cache_store, which Rails
  # derives from this during initialization, before the controllers load.
  #
  # Two backends:
  #   * REDIS_URL set  → Render Key Value (Valkey): in-memory, no fsync, off the
  #     answer database. The load test (docs/SCALE_AND_COST_PLAN.md §2b) found
  #     the 0.1-CPU Postgres pinned at 100% by Solid Cache entries and
  #     rate-limit counter writes at ~2 arrivals/s while the web tier idled —
  #     this is the fix for that. Short timeouts plus an error handler: a cache
  #     hiccup degrades to "uncached" (and rate limits to "open"), it never
  #     fails a respondent's request.
  #   * otherwise      → Solid Cache on the primary database (config/cache.yml),
  #     the previous arrangement and still what production runs until the var
  #     is set. Without an explicit store Rails falls back to a per-process
  #     memory store, which quietly made every rate limit weaker than it
  #     reads: counters lived in one Puma process and were wiped by each
  #     deploy and each memory-watchdog restart.
  config.cache_store = if ENV["REDIS_URL"].present?
    [ :redis_cache_store, {
      url: ENV["REDIS_URL"],
      connect_timeout: 1, read_timeout: 0.5, write_timeout: 0.5, reconnect_attempts: 1,
      error_handler: ->(method:, returning:, exception:) {
        ErrorReporting.report("redis_cache_store", exception, method: method, returning: returning.inspect)
      }
    } ]
  else
    :solid_cache_store
  end

  # Use a real queuing backend for Active Job (and separate queues per environment).
  # Solid Queue on the primary database — see CreateSolidQueueTables for why the
  # queue isn't split onto its own connection. The worker runs inside Puma
  # (config/puma.rb): Render disks mount to exactly one service and Active
  # Storage lives on ours, so a separate worker service couldn't reach the
  # images it needs to write.
  config.active_job.queue_adapter = :solid_queue
  # config.active_job.queue_name_prefix = "survey_poc_production"

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Allow Render-hosted domains, any custom RENDER_EXTERNAL_HOSTNAME, and any
  # custom domain set via APP_HOST (e.g. dashboard.playverto.com).
  config.hosts << /.*\.onrender\.com/
  config.hosts << "playverto.com"
  config.hosts << /.*\.playverto\.com/
  config.hosts << ENV["RENDER_EXTERNAL_HOSTNAME"] if ENV["RENDER_EXTERNAL_HOSTNAME"].present?
  config.hosts << ENV["APP_HOST"]                 if ENV["APP_HOST"].present?
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
