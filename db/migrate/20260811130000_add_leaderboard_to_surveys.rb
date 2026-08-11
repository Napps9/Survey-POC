# The leaderboard of token collectors, shown to respondents at the end of a
# tokenised Verto.
#
# leaderboard_enabled is opt-in (default false) like every new presentation
# feature — a board appearing unannounced on existing Vertos would change what
# their respondents see. It only takes effect while tokenisation_enabled is
# also on (Survey#leaderboard_active?): the board ranks token totals, so
# without tokens there is nothing to rank.
#
# leaderboard_retake_policy is a string enum rather than booleans, per the
# render_mode precedent (20260710112739), so more policies can be added
# without another migration. "accumulate" is the default because it is the
# most game-like reading of a retake — play again, gain points, climb — and
# the least surprising to a respondent who replays. The CHECK constraint
# follows the P2-8 posture (20260730190000): the model normalizes, the
# database enforces, and the two can't drift apart silently.
class AddLeaderboardToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :leaderboard_enabled, :boolean, default: false, null: false
    add_column :surveys, :leaderboard_retake_policy, :string, default: "accumulate", null: false
    add_check_constraint :surveys,
      "leaderboard_retake_policy IN ('accumulate', 'no_redo', 'restart')",
      name: "chk_surveys_leaderboard_retake_policy"
  end
end
