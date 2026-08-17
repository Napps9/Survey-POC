class AddSurveyWaveToResponses < ActiveRecord::Migration[8.1]
  def change
    # Nullable — nil means "pre-wave / wave 1", resolved lazily the first time
    # Survey#start_next_wave! backfills it. No data migration: every existing
    # response already IS wave 1 by that definition, so there's nothing to fill.
    add_reference :responses, :survey_wave, null: true, foreign_key: true, index: false
    add_index :responses, [ :survey_id, :survey_wave_id ]
  end
end
