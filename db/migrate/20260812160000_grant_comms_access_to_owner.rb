# Data migration: make Comms visible in PRODUCTION.
#
# CommsAccess gates on membership of the Playverto org, and the seeds change
# that grants it only runs when a database is created from scratch — Render's
# pre-deploy `db:prepare` migrates an existing database and never re-seeds.
# So the suite shipped fully gated with nobody inside the gate. This runs on
# the ordinary migration path instead, which production does execute.
#
# Idempotent and credential-free: an existing org/user/membership is left
# untouched; a missing user is created password-pending with a throwaway
# password (the partner-account idiom) and claims access through the normal
# password-reset flow. Up-only — revoking access is a product decision made
# through the Members page, not a rollback.
class GrantCommsAccessToOwner < ActiveRecord::Migration[8.1]
  OWNER_EMAIL = "nick@playverto.com".freeze

  def up
    org = Organisation.find_or_create_by!(slug: CommsAccess::PLAYVERTO_SLUG) do |o|
      o.name = "Playverto"
    end

    owner = User.find_or_create_by!(email_address: OWNER_EMAIL) do |u|
      u.name             = "Nick"
      u.password         = SecureRandom.hex(32)
      u.password_pending = true
    end

    Membership.find_or_create_by!(user: owner, organisation: org) do |m|
      m.role = "admin"
    end
  rescue => e
    # Data-only migration: if model drift ever makes this stale, the deploy
    # must not be held hostage — the grant can always be done by hand.
    say "Comms owner grant skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing; see the header.
  end
end
