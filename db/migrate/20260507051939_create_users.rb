class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:users)
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :name, null: false, default: ""
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, :email_address, unique: true
  end
end
