# Whether each answer option shows what it is worth BEFORE the respondent
# picks it — a small "🪙 5" badge per token type beside the option — rather
# than the amount staying hidden until the after-answer reveal.
#
# Defaults false: showing amounts up front changes the instrument (respondents
# optimise for points), so it is the creator's deliberate choice per Verto.
class AddTokenAmountsShownToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :token_amounts_shown, :boolean, default: false, null: false
  end
end
