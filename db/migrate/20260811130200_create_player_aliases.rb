# The system-made anonymous names on a Verto's leaderboard ("Clever Axolotl").
#
# Assign-and-store rather than derive-from-digest: a name must never change
# once a respondent has seen it, even if the word lists are edited later, so
# the assignment is recorded the first time an identity is named. There is
# deliberately no update path anywhere — the names are uneditable by design.
#
# key_digest is the leaderboard's grouping key (responses.player_key_digest).
# Unique per survey in both directions: one name per identity, and no two
# identities share a name on one board.
class CreatePlayerAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :player_aliases do |t|
      t.references :survey, null: false, foreign_key: true
      t.string :key_digest, null: false
      t.string :anon_name, null: false
      t.timestamps
    end
    add_index :player_aliases, [ :survey_id, :key_digest ], unique: true
    add_index :player_aliases, [ :survey_id, :anon_name ], unique: true
  end
end
