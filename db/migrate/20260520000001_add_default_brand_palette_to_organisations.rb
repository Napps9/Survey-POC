class AddDefaultBrandPaletteToOrganisations < ActiveRecord::Migration[8.1]
  def change
    add_column :organisations, :default_brand_palette, :json
  end
end
