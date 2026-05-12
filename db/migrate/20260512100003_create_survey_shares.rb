class CreateSurveyShares < ActiveRecord::Migration[8.1]
  def change
    create_table :survey_shares do |t|
      t.references :survey, null: false, foreign_key: true
      t.references :alliance, null: false, foreign_key: true
      t.string :share_token, null: false
      t.timestamps
    end
    add_index :survey_shares, :share_token, unique: true
    add_index :survey_shares, [ :survey_id, :alliance_id ], unique: true
  end
end
