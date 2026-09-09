# The one cross-Verto join in this application, and the only one there will be.
#
# There is deliberately no `responses.player_id`. That column would be exactly
# the cross-survey key with a name and an email on the end of it that
# survey.rb's player_key_digest comment and ContactDetail's header both promise
# does not exist — and a careless `select` in any creator-facing export would
# leak it. Keeping the join here means `responses` is untouched and erasure has
# one place to look.
#
# response_id is materialised rather than re-derived from a digest at read
# time: render.yaml sets SECRET_KEY_BASE with generateValue: true, so a
# recreated service makes every stored HMAC uncomparable, and an account that
# re-derived would silently empty itself.
class CreatePlayerClaims < ActiveRecord::Migration[8.1]
  def change
    create_table :player_claims do |t|
      t.references :player,   null: false, foreign_key: true
      t.references :survey,   null: false, foreign_key: true
      t.references :response, null: false, foreign_key: true
      t.datetime :claimed_at, null: false
      t.string   :source,     null: false
      t.timestamps
    end

    # A replayed sign-in link, or the same Verto claimed twice from two
    # devices, finds its row instead of creating another.
    add_index :player_claims, [ :player_id, :response_id ], unique: true
    # "How many people took an account on this Verto" — the creator's tile.
    add_index :player_claims, [ :survey_id, :claimed_at ]

    add_check_constraint :player_claims,
      "source IN ('signup', 'signed_in_play', 'device_key')",
      name: "chk_player_claims_source"
  end
end
