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
# `responses: false` — the deck only. The simulated respondents the rake task
# seeds are demo data, and this account is a real one; add them deliberately
# with `bin/rails showcase:seed FORCE=1` if the results screens should have
# numbers in them.
class ProvisionShowcaseVerto < ActiveRecord::Migration[8.0]
  def up
    # Same reasoning as the Alpbach provisioner's reset: production eager-loads,
    # so the models are already cached with their pre-migration columns.
    Survey.reset_column_information
    ShowcaseVertoSeeder.new(responses: false).call
  rescue => e
    # Data-only migration: model drift must not hold a deploy hostage — the
    # Verto can always be seeded by hand with `bin/rails showcase:seed`.
    say "Showcase Verto provisioning skipped: #{e.class}: #{e.message}"
  end

  def down
    # Intentionally nothing; removing it is `bin/rails showcase:destroy`.
  end
end
