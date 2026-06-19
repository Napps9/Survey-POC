# The starter queries already exist as Blazer::Query rows in any environment
# seeded before the internal-org filter was added, and seeds don't re-run on an
# existing database. Push the new SQL into those live rows once, on deploy.
# Fresh installs get the same SQL from db/seeds. Later team edits are preserved
# (this runs a single time, like every migration).
class ResyncBlazerStarterQueriesForInternalFilter < ActiveRecord::Migration[8.1]
  def up
    BlazerStarterQueries.resync!
  end

  def down
    # One-way: the previous, unfiltered SQL isn't worth restoring.
  end
end
