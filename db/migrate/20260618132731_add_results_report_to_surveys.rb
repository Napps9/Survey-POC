class AddResultsReportToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :results_report, :text
    add_column :surveys, :results_report_response_count, :integer
  end
end
