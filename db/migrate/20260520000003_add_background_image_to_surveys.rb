class AddBackgroundImageToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :background_image, :text
  end
end
