class AddNameToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :name, :string, null: false, default: "" unless column_exists?(:users, :name)
  end
end
