class CreateSurveys < ActiveRecord::Migration[8.1]
  def change
    create_table :surveys do |t|
      t.string :title
      t.text :description
      t.string :theme
      t.string :audience_age
      t.text :key_insight
      t.json :cards

      t.timestamps
    end
  end
end
