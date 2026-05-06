class AddPublishTokenToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :publish_token, :string
    add_column :surveys, :published_at,  :datetime
    add_index  :surveys, :publish_token, unique: true
  end
end
