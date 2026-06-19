# Add the "Content — …" starter queries (questions/answers per Verto) to
# databases seeded before they existed. Runs BlazerStarterQueries.resync!, which
# creates the new queries and leaves the rest as-is. Fresh installs get them
# from db/seeds. One-way; runs once like every migration.
class AddBlazerContentQueries < ActiveRecord::Migration[8.1]
  def up
    BlazerStarterQueries.resync!
  end

  def down
    # One-way: dropping the content queries on rollback isn't worth it.
  end
end
