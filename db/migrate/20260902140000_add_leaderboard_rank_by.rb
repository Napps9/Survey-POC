# The leaderboard ranked one number: the sum of every token type. With tokens
# played as several currencies (CO2 saved, lives) that sum means nothing, so
# the creator now picks what the board ranks by — "all" (the original sum) or
# one token type id — and every standing carries each type's total for the
# row's breakdown.
#
# The standings snapshot is derived data (LeaderboardStanding.refresh!), so
# rather than backfilling `totals` it is emptied: bootstrap! recomputes each
# board, breakdown included, the first time it is read.
class AddLeaderboardRankBy < ActiveRecord::Migration[8.1]
  def up
    add_column :surveys, :leaderboard_rank_by, :string, default: "all", null: false
    add_column :leaderboard_standings, :totals, :json, default: {}, null: false
    execute "DELETE FROM leaderboard_standings"
  end

  def down
    remove_column :leaderboard_standings, :totals
    remove_column :surveys, :leaderboard_rank_by
  end
end
