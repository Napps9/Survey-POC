# The precomputed leaderboard: one row per ranked identity per Verto,
# rewritten wholesale by RefreshLeaderboardStandingsJob. Exists so the
# thank-you screen's auto-fetched leaderboard reads an indexed table instead
# of scanning every completed response per finisher — at burst scale that
# scan was O(total responses) per respondent.
class CreateLeaderboardStandings < ActiveRecord::Migration[8.1]
  def change
    create_table :leaderboard_standings do |t|
      t.integer  :survey_id,  null: false
      t.string   :key_digest, null: false
      t.integer  :total,      null: false, default: 0
      t.datetime :achieved_at
      t.integer  :rank,       null: false
      t.timestamps

      t.index [ :survey_id, :rank ], unique: true
      t.index [ :survey_id, :key_digest ], unique: true
      t.index [ :survey_id, :total ]
    end
    add_foreign_key :leaderboard_standings, :surveys
  end
end
