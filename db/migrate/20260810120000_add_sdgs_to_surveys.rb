# Which UN Sustainable Development Goals a Verto's subject matter serves —
# derived automatically by SdgClassifier when a dataset is imported or seeded,
# stored as a sorted list of goal numbers (1..17).
#
# A json list rather than a join table because the only consumer is display
# (chips on the dashboard, Ask Verto sources and the review queue): nothing
# filters or joins on a goal yet, and json is the one array shape that behaves
# identically on sqlite (dev/test) and Postgres (prod). Empty means "no goal
# clearly applies" — a legitimate verdict, not a pending state.
class AddSdgsToSurveys < ActiveRecord::Migration[8.1]
  def change
    add_column :surveys, :sdgs, :json, default: [], null: false
  end
end
