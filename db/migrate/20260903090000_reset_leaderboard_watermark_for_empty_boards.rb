# AddLeaderboardRankBy (2026-09-02 14:00) empties leaderboard_standings so
# every board is rebuilt with the new per-type totals. That was written for a
# board that rebuilt itself whenever it was empty; the refresh is now
# incremental behind surveys.leaderboard_refreshed_at, and an emptied board
# whose watermark still stands would never be rebuilt — the next refresh only
# looks at finishers newer than the watermark. Clear the watermark wherever
# the board is empty so the next read bootstraps it (inline when small, via
# RefreshLeaderboardStandingsJob when big). On a database that ran the
# migrations in timestamp order the column was still NULL here and this is a
# no-op; it matters where the watermark migrations ran first.
class ResetLeaderboardWatermarkForEmptyBoards < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE surveys SET leaderboard_refreshed_at = NULL
      WHERE id NOT IN (SELECT DISTINCT survey_id FROM leaderboard_standings)
    SQL
  end

  def down
    # Nothing to restore: a NULL watermark only means "build on next read".
  end
end
