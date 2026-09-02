# The leaderboard snapshot's incremental high-water mark, stamped only when a
# refresh COMPLETES. It used to be inferred from the snapshot rows' own
# updated_at, which forced a full rebuild to be one giant transaction (a
# partial commit would have advanced the inferred watermark past the
# identities not yet built). With an explicit mark the rebuild can commit
# batch by batch — the load test showed overlapping whole-board transactions
# queueing every request behind them for ~12 s.
class AddLeaderboardRefreshedAtToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :leaderboard_refreshed_at, :datetime
  end
end
