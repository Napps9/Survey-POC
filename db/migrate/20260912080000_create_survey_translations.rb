# The state of ONE language's translation run for one Verto.
#
# It exists because the Language check screen was lying. The rail read
# "Translating…" off a URL parameter left by the redirect, so it said that
# whether the job was running, had finished, had been discarded, or had never
# started — and a reload turned it into a silent "0/20" that reads as a
# failure nobody can tell from a slow success.
#
# There is no other honest source for this. Solid Queue's own rows disappear
# when a job completes or is discarded, so "was this asked for, and what
# happened?" cannot be answered from them after the fact — which is precisely
# the moment a creator asks.
class CreateSurveyTranslations < ActiveRecord::Migration[8.1]
  def change
    create_table :survey_translations do |t|
      t.references :survey, null: false, foreign_key: true
      t.string :locale, null: false
      # queued  — asked for, waiting for a worker
      # running — a Claude call is in flight for this language
      # done    — every card carries an entry
      # failed  — the attempts are spent; last_error says why, and the rail
      #           offers a retry rather than sitting on "Translating…"
      t.string   :status,   null: false, default: "queued"
      t.integer  :attempts, null: false, default: 0
      t.string   :last_error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :survey_translations, [ :survey_id, :locale ], unique: true,
              name: "index_survey_translations_on_survey_and_locale"

    add_check_constraint :survey_translations,
      "status IN ('queued', 'running', 'done', 'failed')",
      name: "chk_survey_translations_status"
  end
end
