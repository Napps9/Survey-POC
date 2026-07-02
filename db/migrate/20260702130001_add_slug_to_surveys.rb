class AddSlugToSurveys < ActiveRecord::Migration[8.1]
  # A creator-chosen alternative to the opaque publish_token in the /play/:token
  # URL (e.g. /play/summer-feedback-2026). Nullable — blank means "no custom
  # link", same convention as consent_text. Availability is checked in
  # SurveysController#update_settings before writing, so the unique index here
  # is a race-condition safety net rather than the primary UX path.
  def change
    add_column :surveys, :slug, :string
    add_index  :surveys, :slug, unique: true
  end
end
