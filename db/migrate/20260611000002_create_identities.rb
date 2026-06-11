class CreateIdentities < ActiveRecord::Migration[8.1]
  def change
    # One row per linked sign-in method (Google / Apple / Microsoft), so a
    # user can attach several providers to the same Playverto account.
    create_table :identities do |t|
      t.integer :user_id, null: false
      t.string  :provider, null: false
      t.string  :uid, null: false
      t.string  :email
      t.string  :name
      t.timestamps
    end
    add_index :identities, :user_id
    add_index :identities, [ :provider, :uid ], unique: true
  end
end
