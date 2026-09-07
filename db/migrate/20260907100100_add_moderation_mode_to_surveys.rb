class AddModerationModeToSurveys < ActiveRecord::Migration[8.1]
  # How a Verto's held free text is decided — see Moderation::MODES. Assisted
  # (the screen's confident verdicts are acted on) is the default because it is
  # the mode that keeps the review queue to the genuinely uncertain; review_all
  # is for a Verto whose audience or subject warrants a person reading every
  # answer.
  def change
    add_column :surveys, :moderation_mode, :string, null: false, default: "assisted"
    add_check_constraint :surveys,
      "moderation_mode IN ('assisted', 'review_all')",
      name: "chk_surveys_moderation_mode"
  end
end
