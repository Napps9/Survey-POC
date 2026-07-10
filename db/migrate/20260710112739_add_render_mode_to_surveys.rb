class AddRenderModeToSurveys < ActiveRecord::Migration[8.1]
  # How the respondent player presents a Verto: "cards" (the default immersive,
  # animated one-question-at-a-time experience) or "form" (the same flow with
  # the swipe gestures and game-like animation stripped, so it reads as a plain
  # questionnaire). A string rather than a boolean so more presentation modes can
  # be added later without another migration — mirrors default_locale.
  def change
    add_column :surveys, :render_mode, :string, default: "cards", null: false
  end
end
