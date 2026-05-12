class AddShowResultsComparisonToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :show_results_comparison, :boolean, default: false, null: false
  end
end
