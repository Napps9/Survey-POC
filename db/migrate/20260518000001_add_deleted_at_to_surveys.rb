class AddDeletedAtToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :deleted_at, :datetime
    add_index  :surveys, :deleted_at
  end
end
