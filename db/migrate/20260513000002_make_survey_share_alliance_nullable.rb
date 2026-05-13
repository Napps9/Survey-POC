class MakeSurveyShareAllianceNullable < ActiveRecord::Migration[8.1]
  def change
    change_column_null :survey_shares, :alliance_id, true
    add_column :survey_shares, :label, :string
    remove_index :survey_shares, name: "index_survey_shares_on_survey_id_and_alliance_id"
    add_index :survey_shares, [ :survey_id, :alliance_id ], unique: true, where: "alliance_id IS NOT NULL"
  end
end
