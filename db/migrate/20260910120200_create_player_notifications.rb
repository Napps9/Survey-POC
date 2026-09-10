# One row per intended send to one respondent about one Verto.
#
# It exists for three reasons, and the row is cheaper than any of them
# separately:
#
#   * Idempotency. Unique on (player_id, survey_id, kind), so a creator who
#     presses Publish twice — or a retried job — cannot mail the same person
#     the same news twice. The database enforces it rather than a check the
#     second request could pass at the same moment as the first.
#   * An unsubscribe token. Both links in the mail need one, and it must be a
#     bearer token bound to this send rather than to the account, so a
#     forwarded email cannot be used to opt somebody else out of anything.
#   * A record. "Did we already tell them?" is a question the creator asks and
#     the support inbox asks, and the answer has to be in the database.
class CreatePlayerNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :player_notifications do |t|
      t.references :player,       null: false, foreign_key: true
      t.references :survey,       null: false, foreign_key: true
      t.references :organisation, null: false, foreign_key: true
      # impact    — what this Verto turned out to change
      # follow_up — a new Verto from an organisation they answered
      t.string   :kind,  null: false
      t.string   :token, null: false
      t.datetime :sent_at
      t.timestamps
    end

    add_index :player_notifications, [ :player_id, :survey_id, :kind ], unique: true,
              name: "index_player_notifications_on_player_survey_kind"
    add_index :player_notifications, :token, unique: true

    add_check_constraint :player_notifications,
      "kind IN ('impact', 'follow_up')", name: "chk_player_notifications_kind"
  end
end
