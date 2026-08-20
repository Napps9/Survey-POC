# Puts the showcase Verto — the one deck that plays every answer type — into the
# Playverto organisation on an EXISTING database.
#
# Needed here as well as in db/seeds.rb for the reason spelled out there and in
# 20260818120001_provision_alpbach_account.rb: the two paths are disjoint. A
# fresh database loads db/schema.rb, marks every migration as already run
# WITHOUT executing it, and then seeds — so seeds.rb is the only thing that
# provisions it there. An existing database (production) never re-seeds
# (`db:prepare` only seeds a database it just created) and runs this instead.
#
# ShowcaseVertoSeeder is create-only, so whichever path runs first, the other is
# a no-op — and neither will ever overwrite edits made to the deck in the editor.
# Rebuilding is a deliberate act: `bin/rails showcase:seed FORCE=1`.
#
# The deck only, in Test Mode — no simulated respondents. Those are demo data
# the rake task seeds on request, and this account is a real one; add them
# deliberately with `bin/rails showcase:seed FORCE=1 PUBLISH=1 RESPONSES=1` if
# the results screens should have numbers in them.
#
# NOTE: an earlier revision of this migration published the Verto. Deploys that
# already ran it are corrected by 20260820140000_showcase_verto_test_mode.rb,
# which is idempotent and reaches the same end state from either side.
class ProvisionShowcaseVerto < ActiveRecord::Migration[8.0]
  def up
    # Same reasoning as the Alpbach provisioner's reset: production eager-loads,
    # so the models are already cached with their pre-migration columns.
    Survey.reset_column_information
    ShowcaseVertoSeeder.new.call
  rescue => e
    # Data-only migration: model drift must not hold a deploy hostage — the
    # Verto can always be seeded by hand with `bin/rails showcase:seed`.
    say "Showcase Verto provisioning skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing; removing it is `bin/rails showcase:destroy`.
  end
end
