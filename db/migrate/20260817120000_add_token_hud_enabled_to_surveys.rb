# Whether the running token pill (.token-score-chip) shows in the player
# footer while a tokenised Verto is in progress.
#
# Defaults true — every tokenised Verto has always shown it. Turning it off
# gives a "blind scoring" mode: checkpoints, per-answer reveal and the final
# tally all keep working from the same stored totals, this only hides the
# live running number.
class AddTokenHudEnabledToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :token_hud_enabled, :boolean, default: true, null: false
  end
end
