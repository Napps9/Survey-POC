# Whether the player's own chrome — Back/Next/Submit, the consent gate, the
# required-field hint, the thank-you screen — follows the Verto's content
# language instead of the visitor's platform locale.
#
# Card content has always followed the Verto's own language
# (Survey#display_locale_for); the surrounding chrome follows whoever's
# looking at it (ApplicationController#resolve_locale) — a Spanish-language
# Verto opened by an English-browser visitor renders Spanish questions
# against English buttons. Defaults false: today's behaviour, unchanged,
# until a creator opts in.
class AddChromeFollowsVertoLanguageToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :chrome_follows_verto_language, :boolean, default: false, null: false
  end
end
