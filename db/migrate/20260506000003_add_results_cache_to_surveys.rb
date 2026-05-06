class AddResultsCacheToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :results_summary,                :text
    add_column :surveys, :results_summary_response_count, :integer
  end
end
