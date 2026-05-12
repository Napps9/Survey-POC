class AddKindToOrganisations < ActiveRecord::Migration[8.1]
  def change
    add_column :organisations, :kind, :string, default: "creator", null: false
    add_index :organisations, :kind
  end
end
