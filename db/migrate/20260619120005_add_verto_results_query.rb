# Add the "Content — Verto results (questions & answers)" starter query to
# databases seeded before it existed. Runs BlazerStarterQueries.resync!, which
# creates the new query and leaves the rest as-is. One-way; runs once.
class AddVertoResultsQuery < ActiveRecord::Migration[8.1]
  def up
    BlazerStarterQueries.resync!
  end

  def down
    # One-way: dropping the query on rollback isn't worth it.
  end
end
