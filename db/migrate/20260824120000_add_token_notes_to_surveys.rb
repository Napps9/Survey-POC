class AddTokenNotesToSurveys < ActiveRecord::Migration[8.1]
  # The two tokenomics lines on the points intro were hardcoded i18n; the
  # owner wants them writable per Verto ("to add own context here about
  # mountain and steps etc" — Feedback 17). Null means the i18n default, so
  # every existing Verto reads exactly as before.
  def change
    add_column :surveys, :tokens_note, :string
    add_column :surveys, :leaderboard_note, :string
  end
end
