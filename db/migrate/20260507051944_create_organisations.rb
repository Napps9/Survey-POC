class CreateOrganisations < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:organisations)
    create_table :organisations do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.timestamps
    end
    add_index :organisations, :slug, unique: true
  end
end
