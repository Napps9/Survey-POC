# Data migration: give nick@playverto.com access to the Alpbach account.
#
# A follow-up rather than an edit to 20260818120001: that migration has already
# run wherever this deployed, and a migration only ever runs once — editing it
# would change nothing on any database that matters.
#
# AlpbachAccountProvisioner now grants both people, and every write in it is
# create-only, so re-running it here adds exactly the missing membership and
# leaves everything the first pass created untouched. No
# reset_column_information needed this time: verto_creation_enabled has existed
# since the migration before last, so no model cache can predate it.
class AddOwnerToAlpbachAccount < ActiveRecord::Migration[8.1]
  def up
    AlpbachAccountProvisioner.new.call
  rescue => e
    # Data-only migration: never hold a deploy hostage — the membership can
    # always be granted by hand, or through the Members page.
    say "Alpbach owner grant skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing — removing someone's access is a product decision.
  end
end
