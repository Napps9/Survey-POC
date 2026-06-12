class AddCompareNoteToSurveys < ActiveRecord::Migration[8.1]
  def change
    # Editable "you can compare your results" promise shown on the welcome
    # card when show_results_comparison is on (replaces the old top banner).
    add_column :surveys, :compare_note, :string
  end
end
