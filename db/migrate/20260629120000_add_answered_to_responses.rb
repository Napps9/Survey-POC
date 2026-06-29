class AddAnsweredToResponses < ActiveRecord::Migration[8.1]
  # Denormalised "answered at least one question" flag. The dashboard needs a
  # per-survey responder count, which previously meant loading every response's
  # `answers` JSON and inspecting it in Ruby (the 3-5s SurveysController#index
  # ActiveRecord time in the logs). With this flag the dashboard can count
  # responders with a grouped SQL query and never load the JSON. Kept in sync by
  # a before_save on Response. A composite index serves the dashboard's grouped
  # counts (responders, and responders-who-completed, per survey).
  def up
    add_column :responses, :answered, :boolean, default: false, null: false
    add_index  :responses, [ :survey_id, :answered, :status ], name: "index_responses_on_survey_answered_status"

    # Backfill existing rows from their stored answers. update_column skips the
    # model callback/validation and touches only this column.
    Response.reset_column_information
    Response.find_each do |r|
      answered = r.answers.is_a?(Hash) &&
                 r.answers.values.any? { |a| a.is_a?(Hash) && a["value"].present? }
      r.update_column(:answered, answered)
    end
  end

  def down
    remove_index  :responses, name: "index_responses_on_survey_answered_status"
    remove_column :responses, :answered
  end
end
