class AddResultsReportEditingToSurveys < ActiveRecord::Migration[8.1]
  def change
    # When the creator hand-edited the cached AI report (nil = untouched AI text).
    add_column :surveys, :results_report_edited_at, :datetime
    # The creator's report brief (goal / audience / length), JSON-encoded, so
    # count-triggered regenerations reuse it instead of the generic prompt.
    add_column :surveys, :results_report_brief, :text
  end
end
