class CreateSurveyWaves < ActiveRecord::Migration[8.1]
  def change
    create_table :survey_waves do |t|
      t.references :survey, null: false, foreign_key: true
      t.integer  :position, null: false
      t.string   :label
      t.datetime :opened_at, null: false
      t.datetime :closed_at

      t.timestamps
    end
    add_index :survey_waves, [ :survey_id, :position ], unique: true
  end
end
