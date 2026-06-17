class AddConsentTextToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :consent_text, :text
  end
end
