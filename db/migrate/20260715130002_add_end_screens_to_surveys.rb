class AddEndScreensToSurveys < ActiveRecord::Migration[8.1]
  # Extra end screens for answer-branching: a branch can finish on its own
  # thank-you screen (e.g. a per-hub Stripe link) instead of the shared one.
  # This column holds only the ADDITIONAL screens; the built-in "default" screen
  # stays in the legacy thankyou_title / thankyou_body / forward_url columns, so
  # nothing about the existing single thank-you changes. No backfill needed —
  # Survey#end_screens_list synthesises the default from those legacy columns.
  def change
    add_column :surveys, :end_screens, :json, default: [], null: false
  end
end
