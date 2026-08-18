# Data migration: create the Alpbach client account and Jamie's memberships in
# PRODUCTION.
#
# Render's pre-deploy `db:prepare` migrates an existing database and never
# re-seeds, so db/seeds.rb would never run — this has to ride the ordinary
# migration path, exactly as GrantCommsAccessToOwner does.
#
# Idempotent and credential-free; all the reasoning lives on
# AlpbachAccountProvisioner. Up-only: withdrawing an account is a product
# decision made through the Members page, not a rollback.
class ProvisionAlpbachAccount < ActiveRecord::Migration[8.1]
  def up
    # The migration immediately before this one added verto_creation_enabled.
    # Production eager-loads (config.eager_load = true), so Organisation is
    # already loaded — with its pre-migration columns cached — by the time
    # `db:prepare` runs these. Writing the new attribute against that stale
    # cache raises UnknownAttributeError, which the rescue below would turn
    # into a one-line log nobody reads, leaving a green deploy and no Alpbach
    # account. Development can't reproduce it (eager_load false), which is
    # exactly why it is worth an explicit line rather than a local test.
    Organisation.reset_column_information
    AlpbachAccountProvisioner.new.call
  rescue => e
    # Data-only migration: if model drift ever makes this stale, the deploy
    # must not be held hostage — the account can always be provisioned by hand.
    say "Alpbach account provisioning skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing; see the header.
  end
end
