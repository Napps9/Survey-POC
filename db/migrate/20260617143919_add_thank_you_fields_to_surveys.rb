class AddThankYouFieldsToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :thankyou_title, :string
    add_column :surveys, :thankyou_body, :text
    add_column :surveys, :forward_url, :string
  end
end
