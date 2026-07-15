class AddFunderEnabledToOrganisations < ActiveRecord::Migration[8.0]
  def change
    add_column :organisations, :funder_enabled, :boolean, default: false, null: false
  end
end
