# responses carries eleven [survey_id, *] composite indexes, any of which
# serves a bare survey_id lookup via its leading column — the standalone
# survey_id index is pure write amplification, and every respondent save
# maintains it for nothing. At burst scale that's hundreds of thousands of
# needless index writes.
class DropRedundantResponsesSurveyIdIndex < ActiveRecord::Migration[8.1]
  def up
    remove_index :responses, name: "index_responses_on_survey_id"
  end

  def down
    add_index :responses, :survey_id, name: "index_responses_on_survey_id"
  end
end
