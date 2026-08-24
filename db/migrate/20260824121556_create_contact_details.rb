# The contact register: details a respondent volunteers at the contact gate,
# held APART from their answers by design. Answers stay pseudonymous on the
# response rows; this table is the identified half, and the only bridge between
# the two is key_digest — the same per-survey HMAC of the durable player key
# that names the respondent on the leaderboard (PlayerAlias). Per-survey HMAC
# means contact identities cannot be joined across Vertos, same property the
# leaderboard already holds.
#
# One row per (survey, device identity): re-registration updates in place, so
# playing again never duplicates a contact.
class CreateContactDetails < ActiveRecord::Migration[8.1]
  def change
    create_table :contact_details do |t|
      t.references :survey, null: false, foreign_key: true
      t.string :key_digest, null: false
      t.string :name
      t.string :email
      t.string :company
      t.string :industry
      t.timestamps
    end
    add_index :contact_details, [ :survey_id, :key_digest ], unique: true

    # The creator switch for the contact gate. Off by default: collecting
    # identified data is an explicit choice, never a side effect.
    add_column :surveys, :contact_form_enabled, :boolean, default: false, null: false
  end
end
