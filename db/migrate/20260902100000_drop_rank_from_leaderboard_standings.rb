# The stored rank forced every refresh to rewrite the WHOLE board (a rank is a
# property of the ordering, so one new finisher renumbers everyone). The
# load test measured what that costs at 50,000 identities: the refresh job
# materialised 50k rows in Ruby and delete+inserted 50k rows every 3 s
# window, which OOM-killed a 512 MB instance and would have meant ~30k row
# writes/s on Postgres for the whole event. Rank is now derived at read time
# from the indexed (survey_id, total) column, and refreshes upsert only the
# identities that changed.
class DropRankFromLeaderboardStandings < ActiveRecord::Migration[8.1]
  def change
    remove_index  :leaderboard_standings, [ :survey_id, :rank ], unique: true
    remove_column :leaderboard_standings, :rank, :integer, null: false
  end
end
