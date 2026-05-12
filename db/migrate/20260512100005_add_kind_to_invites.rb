class AddKindToInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :invites, :kind, :string, default: "member", null: false
    add_index :invites, :kind
  end
end
