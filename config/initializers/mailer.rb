# ── Action Mailer SMTP configuration ─────────────────────────
# Driven entirely by environment variables so the same code works
# with any free transactional-email provider:
#
#   Brevo (300/day free)  smtp-relay.brevo.com           : 587
#   SendGrid  (100/day)   smtp.sendgrid.net              : 587   user "apikey"
#   Resend    (3k/mo)     smtp.resend.com                : 465   user "resend"
#   Mailtrap sandbox/live sandbox.smtp.mailtrap.io / live.smtp.mailtrap.io : 587|2525
#   Gmail SMTP (low cap)  smtp.gmail.com                 : 587   app-password
#
# Set SMTP_ADDRESS to enable; if missing we leave Rails defaults
# in place (development logs to stdout, tests use :test adapter).

if ENV["SMTP_ADDRESS"].present?
  Rails.application.config.action_mailer.delivery_method = :smtp
  Rails.application.config.action_mailer.smtp_settings = {
    address:              ENV["SMTP_ADDRESS"],
    port:                 ENV.fetch("SMTP_PORT", 587).to_i,
    domain:               ENV["SMTP_DOMAIN"].presence || ENV["MAIL_FROM"].to_s.split("@").last,
    user_name:            ENV["SMTP_USERNAME"],
    password:             ENV["SMTP_PASSWORD"],
    authentication:       ENV.fetch("SMTP_AUTHENTICATION", "plain").to_sym,
    enable_starttls_auto: ENV.fetch("SMTP_STARTTLS", "true") == "true",
    tls:                  ENV["SMTP_TLS"] == "true"
  }.compact
elsif Rails.env.production?
  # Without SMTP_ADDRESS, delivery falls back to Rails' bare default (smtp to
  # localhost:25), which fails on Render. PasswordsController and friends
  # rescue that failure and still show a success message, so a misconfigured
  # deploy has no visible symptom anywhere except this line — password
  # resets, invites, and account-setup emails all silently go nowhere.
  Rails.logger.warn(
    "[Mailer] SMTP_ADDRESS is not set — outbound email (password resets, invites, " \
    "account setup links) cannot be delivered. Set SMTP_ADDRESS/SMTP_USERNAME/" \
    "SMTP_PASSWORD/MAIL_FROM in the Render dashboard (see .env.example)."
  )
end

# Public host used to build links inside emails (password reset, etc.)
# Render injects RENDER_EXTERNAL_HOSTNAME automatically; APP_HOST wins
# when a custom domain is attached.
host = ENV["APP_HOST"].presence || ENV["RENDER_EXTERNAL_HOSTNAME"].presence
if host
  proto = ENV.fetch("APP_PROTOCOL", "https")
  Rails.application.config.action_mailer.default_url_options = { host: host, protocol: proto }
  Rails.application.routes.default_url_options[:host]        = host
  Rails.application.routes.default_url_options[:protocol]    = proto
end
