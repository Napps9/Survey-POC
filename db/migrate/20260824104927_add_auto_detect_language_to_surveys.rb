# The player has always opened a multilingual Verto in the respondent's own
# browser language when the Verto carries it (PlayerController#resolve_play_locale).
# Creators asked for that to be theirs to switch off — "when a Verto is opened
# it will revert to the system language, this needs to be controlled by the
# creator". Default true: every existing Verto keeps the behaviour it has.
class AddAutoDetectLanguageToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :auto_detect_language, :boolean, default: true, null: false
  end
end
