# Shared plumbing for the Comms suite (email campaigns).
module Comms
  module_function

  # Every email_* column stores addresses pre-normalized so uniqueness and
  # joins are plain string comparisons — no LOWER() in SQL, which is exactly
  # where SQLite and Postgres disagree (see CLAUDE.md).
  def normalize_email(value)
    value.to_s.strip.downcase
  end

  # The bare address inside MAIL_FROM ("Playverto <no-reply@x>" or a plain
  # address), for composing a from with a per-campaign display name.
  def from_address
    raw = ENV.fetch("MAIL_FROM", "no-reply@playverto.local")
    raw[/<([^>]+)>/, 1] || raw
  end

  # The app's public origin (mailer default_url_options), for absolutizing
  # asset paths in compiled email HTML. Blank when no host is configured.
  def app_origin
    opts = ActionMailer::Base.default_url_options || {}
    return "" if opts[:host].blank?

    "#{opts[:protocol] || "https"}://#{opts[:host]}#{opts[:port] ? ":#{opts[:port]}" : ""}"
  end
end
