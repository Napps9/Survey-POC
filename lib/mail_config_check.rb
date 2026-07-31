# frozen_string_literal: true

# Turns a silently-broken mail configuration into something you find out about.
#
# Without SMTP_ADDRESS, Action Mailer falls back to Rails' bare default — SMTP
# to localhost:25 — which fails on Render. Every caller rescues that failure and
# still reports success to the user: PasswordsController redirects with "reset
# instructions sent" regardless, EmailConfirmationsController.deliver swallows
# its own errors by design so a mail failure can't roll back a signup. So a
# deploy missing one env var loses every password reset, every invite, every
# funder and partner account-setup link, and every email confirmation, with no
# symptom anywhere except one log line that scrolls off a Render dashboard in
# seconds.
#
# `default_url_options` has the same shape and is worse: a missing host raises
# inside the Solid Queue job that builds the link, where nobody is looking.
#
# Two levels, deliberately:
#
#   report (default) — log plus a Sentry event, so it reaches someone.
#   raise  (STRICT_MAIL_CONFIG=1) — refuse to boot. render.yaml's
#           autoDeployTrigger/preDeployCommand model turns that into a blocked
#           deploy with the old instance still serving, which is the right
#           outcome once the production values are known-good. It is opt-in
#           because turning it on before then converts a fixable
#           misconfiguration into an outage.
module MailConfigCheck
  module_function

  # Every problem with the current environment, as human-readable strings.
  # Pure: takes an env hash, touches nothing. This is what the tests drive.
  def problems(env = ENV)
    found = []

    if env["SMTP_ADDRESS"].to_s.strip.empty?
      found << "SMTP_ADDRESS is not set — outbound email (password resets, invites, " \
               "account setup links, email confirmations) cannot be delivered. " \
               "Set SMTP_ADDRESS/SMTP_USERNAME/SMTP_PASSWORD/MAIL_FROM (see .env.example)."
    end

    if env["APP_HOST"].to_s.strip.empty? && env["RENDER_EXTERNAL_HOSTNAME"].to_s.strip.empty?
      found << "Neither APP_HOST nor RENDER_EXTERNAL_HOSTNAME is set — Action Mailer has no " \
               "default_url_options, so every link inside an email raises when the mailer job " \
               "renders it. Set APP_HOST to the public hostname."
    end

    found
  end

  def strict?(env = ENV)
    %w[1 true yes].include?(env["STRICT_MAIL_CONFIG"].to_s.downcase)
  end

  # Called from an after_initialize hook so Sentry (config/initializers/sentry.rb)
  # is already configured — initializers run alphabetically, and `mailer` sorts
  # before `sentry`, so reporting from the initializer body itself would only
  # ever reach the log.
  def run!(env = ENV, logger: Rails.logger)
    found = problems(env)
    return found if found.empty?

    message = "[Mailer] #{found.size} mail configuration problem(s): #{found.join(' | ')}"
    raise message if strict?(env)

    logger&.warn(message)
    ErrorReporting.report("MailConfig", MisconfiguredError.new(message))
    found
  end

  # Carries the message to Sentry. Never raised unless STRICT_MAIL_CONFIG is on —
  # ErrorReporting.capture wants an exception, and an unraised one is the
  # conventional way to send a condition rather than a crash.
  class MisconfiguredError < StandardError; end
end
