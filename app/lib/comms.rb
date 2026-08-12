# Shared plumbing for the Comms suite (email campaigns).
module Comms
  module_function

  # Every email_* column stores addresses pre-normalized so uniqueness and
  # joins are plain string comparisons — no LOWER() in SQL, which is exactly
  # where SQLite and Postgres disagree (see CLAUDE.md).
  def normalize_email(value)
    value.to_s.strip.downcase
  end
end
