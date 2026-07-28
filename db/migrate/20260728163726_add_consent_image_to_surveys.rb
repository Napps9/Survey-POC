class AddConsentImageToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :consent_image, :text
    add_column :surveys, :consent_image_credit, :string
    add_column :surveys, :consent_image_credit_url, :string
  end
end
