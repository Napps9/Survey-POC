require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SurveyPoc
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.2

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Internationalization. Available locales come from the language registry
    # (config/supported_locales.yml) — read directly here rather than via the
    # autoloaded SupportedLocales constant, which isn't available during boot.
    # Missing UI translations fall back to English.
    config.i18n.available_locales =
      YAML.load_file(File.expand_path("supported_locales.yml", __dir__))
          .fetch("locales").map { |l| l.fetch("code").to_sym }
    config.i18n.default_locale = :en
    config.i18n.fallbacks = true

    # Active Record Encryption — protects the per-user Google OAuth tokens
    # (User#google_refresh_token / #google_access_token). Set here (not in an
    # initializer) because the framework reads this config before
    # config/initializers run. Production must supply real, persistent keys via
    # ENV; dev/test use disposable keys so the feature works without setup.
    if (primary = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]).present?
      config.active_record.encryption.primary_key         = primary
      config.active_record.encryption.deterministic_key   = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
      config.active_record.encryption.key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
    elsif !Rails.env.production?
      config.active_record.encryption.primary_key         = "dev_only_ar_encryption_primary_key_0000000001"
      config.active_record.encryption.deterministic_key   = "dev_only_ar_encryption_deterministic_key_00002"
      config.active_record.encryption.key_derivation_salt = "dev_only_ar_encryption_key_derivation_salt_003"
    end
  end
end
