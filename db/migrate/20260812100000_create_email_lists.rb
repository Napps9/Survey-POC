# Imported contact lists for Comms campaigns: first-class rows, not a json
# array — suppression subtraction and dedup are SQL joins, per-contact state
# needs a place to live, and multi-MB json columns are the documented memory
# trap (see Survey::CardImageStore's header for the history).
class CreateEmailLists < ActiveRecord::Migration[8.1]
  def change
    create_table :email_lists do |t|
      t.string  :name, null: false
      t.integer :created_by_id
      t.integer :contacts_count, null: false, default: 0
      t.timestamps

      t.index :created_at
    end

    create_table :email_list_contacts do |t|
      t.integer :email_list_id, null: false
      # Stored pre-normalized (strip.downcase) so uniqueness is a plain string
      # index — no LOWER(), which is where SQLite and Postgres disagree.
      t.string  :email, null: false
      t.string  :name
      t.timestamps

      t.index [ :email_list_id, :email ], unique: true
    end
  end
end
