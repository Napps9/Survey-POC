# A respondent's per-ORGANISATION mail preference, which the app has never had.
#
# EmailSuppression is unique on `email` alone and is subtracted from every
# campaign and automation send — so a respondent pressing unsubscribe today
# would also silence the results digest of a creator who happens to use the
# same address. Creators play their own Vertos, so that is a matter of time
# rather than a hypothetical.
#
# This is the narrower option that makes the honest label possible: "only stop
# emails from Riverside Youth Trust" alongside "stop all Playverto emails".
# Without it the only available link means "stop everything Playverto ever
# sends you", which is not something to offer a person who wants fewer emails
# from one council.
#
# A row is an OPT-OUT. No row means they still hear from that organisation,
# which is what they asked for when they gave the address.
class CreatePlayerEmailPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :player_email_preferences do |t|
      t.references :player,       null: false, foreign_key: true
      t.references :organisation, null: false, foreign_key: true
      t.datetime   :unsubscribed_at, null: false
      t.timestamps
    end

    add_index :player_email_preferences, [ :player_id, :organisation_id ], unique: true,
              name: "index_player_email_prefs_on_player_and_org"
  end
end
