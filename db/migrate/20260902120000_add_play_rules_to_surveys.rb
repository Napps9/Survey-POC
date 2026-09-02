class AddPlayRulesToSurveys < ActiveRecord::Migration[8.1]
  # Two play rules that used to be tangled into the leaderboard's retake
  # policy. Both are new behaviours, so both default off; the policy itself
  # keeps its three values and becomes scoring-only (see Survey).
  #
  #   no_going_back — once a respondent moves on from a question the answer is
  #                   final: Back is hidden and a later change is refused.
  #   no_retests    — one completed run per person per wave.
  #
  # Backfill: the old "No redos" gate only ever fired where the board was live
  # (the player needed leaderboardValue && leaderboardUrlValue, and the page
  # sets leaderboard_mode = tokenisation && leaderboard_enabled), so only THOSE
  # Vertos carry the new flag. A no_redo policy with tokens or the board
  # switched off gated nothing before and must not start gating now.
  class Survey < ActiveRecord::Base; end

  def up
    add_column :surveys, :no_going_back, :boolean, default: false, null: false
    add_column :surveys, :no_retests,    :boolean, default: false, null: false
    Survey.reset_column_information
    Survey.where(leaderboard_retake_policy: "no_redo", leaderboard_enabled: true, tokenisation_enabled: true)
          .update_all(no_retests: true)
  end

  def down
    remove_column :surveys, :no_retests
    remove_column :surveys, :no_going_back
  end
end
