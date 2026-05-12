class AddSurveyShareToResponses < ActiveRecord::Migration[8.1]
  def change
    add_reference :responses, :survey_share, null: true, foreign_key: true
  end
end
