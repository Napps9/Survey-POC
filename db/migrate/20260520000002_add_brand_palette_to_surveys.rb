class AddBrandPaletteToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :brand_palette, :json
  end
end
