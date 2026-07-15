class AddLogicToSurveys < ActiveRecord::Migration[8.1]
  # Answer-branching ("logic"): when on, a single-pick question can route each
  # answer to a different next card or end screen instead of the linear flow.
  # Mirrors the existing per-feature survey flags (quiz, tokenisation_enabled).
  def change
    add_column :surveys, :logic, :boolean, default: false, null: false
  end
end
