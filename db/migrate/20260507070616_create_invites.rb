class CreateInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :invites do |t|
      t.string     :email_address, null: false
      t.string     :token,         null: false
      t.string     :role,          null: false, default: "member"
      t.references :organisation,  null: false, foreign_key: true
      t.references :invited_by,    null: false, foreign_key: { to_table: :users }
      t.datetime   :expires_at,    null: false
      t.datetime   :accepted_at
      t.timestamps
    end
    add_index :invites, :token, unique: true
  end
end
