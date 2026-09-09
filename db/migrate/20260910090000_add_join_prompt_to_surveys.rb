# The end-of-Verto ask: "keep your answers, and hear what happens next".
#
# Off by default, and that is the whole safety story for this feature — a
# respondent sees nothing new until a creator deliberately turns it on, so
# every intermediate deploy is inert. Contrast the "After they finish"
# toggles, which default ON because they were hardcoded on before the panel
# existed and defaulting them off would have withdrawn a live feature.
#
# The three copy fields are nullable: nil means the locale default
# (player.join_title / join_body / join_cta), the same contract as
# compare_note, tokens_note and the thank-you copy.
class AddJoinPromptToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :join_prompt_enabled, :boolean, default: false, null: false
    add_column :surveys, :join_title, :string
    add_column :surveys, :join_body,  :string
    add_column :surveys, :join_cta,   :string
  end
end
